--!strict
-- =============================================================================
--  TomoriCrystalController  |  LocalScript
--  StarterPlayer > StarterPlayerScripts
--
--  責務:
--    CollectionService タグ "GlowCrystal" を持つ全 BasePart の発光を、
--    単一コントローラーが一括管理する。
--
--  ■ なぜ LocalScript なのか
--    PointLight.Brightness / Part.Color はクライアント描画パイプライン上の
--    処理であり、サーバー経由では必ずネットワーク遅延が乗る。距離計算は
--    「自分自身のキャラクター位置」にしか依存しないため、サーバーに負荷を
--    掛ける理由がない。
--
--  ■ なぜ TweenService を使わないのか
--    TweenService は「ある値からある値へ」の一方通行アニメーションに優れるが、
--    「プレイヤーの距離に連続的に追従する」用途では毎フレームキャンセル&再生が
--    必要になり、繋ぎ目が不自然になる。
--    RunService.Heartbeat + 指数平滑化（Exponential Moving Average）を使えば、
--    フレームレート非依存でかつ距離変化に滑らかかつ瞬時に応答できる。
--
--  ■ 発光アルゴリズム概要（Heartbeat ごとに全結晶に適用）
--    [1] 距離  → smoothstep カーブ → 目標影響度 targetInf [0, 1]
--    [2] targetInf を指数平滑化 → influence（フレームレート非依存）
--    [3] 覚醒パルス: influence が闇から浮上した瞬間の減衰正弦波フラッシュ
--    [4] 呼吸波形を3層合成:
--          Layer1: 低速 sine 波（主呼吸 ≈ 4.5s 周期）
--          Layer2: Micro-tremor（黄金比² 周波数で非周期化）
--          Layer3: Perlin noise 2オクターブ（有機的不規則性）
--    [5] 合成波を PointLight.Brightness / Range / Color に適用
--    [6] Part.Color の HSV.Value 成分のみを揺らし「光が呼吸する」表現
-- =============================================================================

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ---------------------------------------------------------------------------
-- モジュールの読み込み
-- WaitForChild に timeout を設定し、Rojo 同期ミスを明確にエラーとして出す
-- ---------------------------------------------------------------------------
local tomoriFolder = ReplicatedStorage:WaitForChild("Tomori", 15)
assert(tomoriFolder, "[TomoriCrystalController] ReplicatedStorage.Tomori が見つかりません。Rojo 同期を確認してください。")

local Config = require(tomoriFolder:WaitForChild("Config",  10) :: ModuleScript)
local Types  = require(tomoriFolder:WaitForChild("Types",   10) :: ModuleScript)

type CrystalData = Types.CrystalData

-- ===========================================================================
-- ■ 定数（Config から切り出してループ内アクセスを高速化）
-- ===========================================================================
local OUTER_RADIUS      = Config.OUTER_RADIUS
local INNER_RADIUS      = Config.INNER_RADIUS
local OUTER_MINUS_INNER = OUTER_RADIUS - INNER_RADIUS
local INFLUENCE_SPEED   = Config.INFLUENCE_SPEED

local FAR               = Config.FAR
local NEAR              = Config.NEAR
local B                 = Config.BREATH
local AWAKE_THRESHOLD   = Config.AWAKE_THRESHOLD
local AWAKE_FREQ_2PI    = Config.AWAKE_FREQ * math.pi * 2
local AWAKE_DECAY       = Config.AWAKE_DECAY
local AWAKE_AMP_B       = Config.AWAKE_AMP_B
local REMOTE_COOLDOWN   = Config.REMOTE_FIRE_COOLDOWN
local REMOTE_INF_FACTOR = Config.REMOTE_INFLUENCE_FACTOR

-- FAR→NEAR のデルタを先計算（差分は不変なので毎フレーム計算しない）
local DELTA_BRIGHTNESS  = NEAR.LightBrightness - FAR.LightBrightness
local DELTA_RANGE       = NEAR.LightRange      - FAR.LightRange

-- 呼吸波形の周波数を 2π 倍に変換（ループ内の乗算コストを減らす）
local FREQ_BASE_2PI     = B.FREQ_BASE    * math.pi * 2
local FREQ_TREMOR_2PI   = B.FREQ_TREMOR  * math.pi * 2
local FREQ_NOISE_1      = B.FREQ_NOISE_1
local FREQ_NOISE_2      = B.FREQ_NOISE_2

-- ===========================================================================
-- ■ 内部状態
-- ===========================================================================
local player    = Players.LocalPlayer
local registry  : { [BasePart]: CrystalData } = {}
local clock     = 0   -- グローバル経過時間（全呼吸波形の共通時間軸）

-- サーバーへの送信状態を管理するテーブル（Character リセット時に再生成）
local firedActive       : { [BasePart]: boolean } = {}
local remoteFireCooldown: { [BasePart]: number  } = {}

-- RemoteEvent（マルチプレイヤー同期）- optional
-- 5秒以内に見つからなければマルチ同期なしで動作する
local remotesFolder  = ReplicatedStorage:WaitForChild(Config.REMOTE_FOLDER_NAME, 5) :: Folder?
local remActivated   = remotesFolder and remotesFolder:FindFirstChild(Config.REMOTE_ACTIVATED)   :: RemoteEvent?
local remDeactivated = remotesFolder and remotesFolder:FindFirstChild(Config.REMOTE_DEACTIVATED) :: RemoteEvent?

-- ===========================================================================
-- ■ ユーティリティ
-- ===========================================================================

-- Color3 の線形補間（ガンマ空間・最小コスト実装）
local function lerpColor(a: Color3, b: Color3, t: number): Color3
    return Color3.new(
        a.R + (b.R - a.R) * t,
        a.G + (b.G - a.G) * t,
        a.B + (b.B - a.B) * t
    )
end

-- PointLight を取得、存在しなければ FAR 状態の初期値で生成して返す
local function ensurePointLight(part: BasePart): PointLight
    local found = part:FindFirstChildOfClass("PointLight")
    if found then return found :: PointLight end

    local light         = Instance.new("PointLight")
    light.Brightness    = FAR.LightBrightness
    light.Range         = FAR.LightRange
    light.Color         = FAR.LightColor
    light.Shadows       = true
    light.Enabled       = true
    light.Parent        = part
    return light
end

-- ===========================================================================
-- ■ クリスタルの登録 / 解除
-- ===========================================================================

local function registerCrystal(part: BasePart)
    if registry[part] then return end  -- 二重登録を防ぐ

    -- Neon マテリアル固定。これにより Part.Color の明度が
    -- そのまま自発光量として描画される。マテリアル切替のフラッシュを避けるため
    -- 起動時に一度だけ設定する。
    part.Material = Enum.Material.Neon
    part.Color    = FAR.Color

    registry[part] = {
        part          = part,
        light         = ensurePointLight(part),
        influence     = 0,
        prevInfluence = 0,
        -- seedA/seedB は個体ごとのランダムな位相オフセットとして機能する。
        -- これにより複数の結晶が完全に同期して点滅するのを防ぐ。
        seedA         = math.random(0, 99999),
        seedB         = math.random(0, 99999),
        awakeAt       = 0,
        awakeActive   = false,
        remoteInf     = 0,
    }
end

local function unregisterCrystal(part: BasePart)
    registry[part] = nil
end

-- ===========================================================================
-- ■ CollectionService フック
-- ===========================================================================

CollectionService:GetInstanceAddedSignal(Config.CRYSTAL_TAG):Connect(function(inst)
    if inst:IsA("BasePart") then
        registerCrystal(inst :: BasePart)
    end
end)

CollectionService:GetInstanceRemovedSignal(Config.CRYSTAL_TAG):Connect(function(inst)
    unregisterCrystal(inst :: BasePart)
end)

-- 起動時に既存のタグ付きオブジェクトを全て登録する
for _, inst in CollectionService:GetTagged(Config.CRYSTAL_TAG) do
    if inst:IsA("BasePart") then
        registerCrystal(inst :: BasePart)
    end
end

-- ===========================================================================
-- ■ マルチプレイヤー同期：他プレイヤーの接近/離脱イベントを受信
-- ===========================================================================

if remActivated then
    remActivated.OnClientEvent:Connect(function(targetPart: Instance)
        if not targetPart:IsA("BasePart") then return end
        local data = registry[targetPart :: BasePart]
        if data then
            data.remoteInf = REMOTE_INF_FACTOR
        end
    end)
end

if remDeactivated then
    remDeactivated.OnClientEvent:Connect(function(targetPart: Instance)
        if not targetPart:IsA("BasePart") then return end
        local data = registry[targetPart :: BasePart]
        if data then
            data.remoteInf = 0
        end
    end)
end

-- ===========================================================================
-- ■ メインループ（RunService.Heartbeat）
-- ===========================================================================

RunService.Heartbeat:Connect(function(dt: number)
    clock += dt

    local char    = player.Character
    local root    = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not root then return end

    local rootPos = root.Position

    for _, data in registry do

        -- Guard: Part が削除・Workspace 外になっていたらスキップ
        if not data.part.Parent then continue end

        -- -------------------------------------------------------------------
        --  STEP 1: 距離 → 目標影響度（smoothstep カーブ）
        --
        --  smoothstep:  f(t) = t² × (3 – 2t),  t ∈ [0, 1]
        --  線形に対して両端の傾きがゼロになるため、境界での急変を排除する。
        --  視覚的には「エッジでの急な切り替わりがなく、自然に滲む」感じ。
        -- -------------------------------------------------------------------
        local dist      = (data.part.Position - rootPos).Magnitude
        local targetInf : number

        if dist >= OUTER_RADIUS then
            targetInf = 0
        elseif dist <= INNER_RADIUS then
            targetInf = 1
        else
            local raw = 1 - (dist - INNER_RADIUS) / OUTER_MINUS_INNER
            targetInf = raw * raw * (3 - 2 * raw)   -- smoothstep(0, 1, raw)
        end

        -- -------------------------------------------------------------------
        --  STEP 2: 指数平滑化（Exponential Moving Average）
        --
        --  alpha = 1 - e^(-speed × dt) を使うと、どのフレームレートでも
        --  同一の収束曲線を保証できる（フレームレート非依存）。
        --  speed が大きいほど素早く targetInf に追従する。
        -- -------------------------------------------------------------------
        data.prevInfluence = data.influence
        local alpha        = 1 - math.exp(-INFLUENCE_SPEED * dt)
        data.influence    += (targetInf - data.influence) * alpha

        -- 他プレイヤーからの remoteInf を加算してクランプ（最大 1.0）
        local inf = math.min(data.influence + data.remoteInf, 1)

        -- -------------------------------------------------------------------
        --  STEP 3: 覚醒パルス（Rising Edge 検出）
        --
        --  prevInfluence < threshold ≤ influence の条件が成立したとき、
        --  結晶が「目覚めた」と判定して減衰正弦波パルスを発火する。
        --  数式: e^(-decay × t) × sin(freq × 2π × t)
        --  これにより「ふわっと光が灯る」一回性の輝きが生まれる。
        -- -------------------------------------------------------------------
        if data.prevInfluence < AWAKE_THRESHOLD
        and data.influence    >= AWAKE_THRESHOLD
        then
            data.awakeAt     = clock
            data.awakeActive = true
        end

        local awakePulseBright = 0.0
        if data.awakeActive then
            local elapsed   = clock - data.awakeAt
            local envDecay  = math.exp(-AWAKE_DECAY * elapsed)
            awakePulseBright = envDecay
                             * math.sin(elapsed * AWAKE_FREQ_2PI)
                             * AWAKE_AMP_B

            -- 包絡線が十分小さくなったらフラグを解除してコストを節約する
            if envDecay < 0.005 then
                data.awakeActive = false
            end
        end

        -- 完全暗闇かつパルスなし → プロパティを FAR 値にリセットしてスキップ
        if inf < 0.002 and not data.awakeActive then
            data.light.Brightness = FAR.LightBrightness
            data.light.Range      = FAR.LightRange
            data.light.Color      = FAR.LightColor
            data.part.Color       = FAR.Color
            continue
        end

        -- -------------------------------------------------------------------
        --  STEP 4: 3層の有機的呼吸波形を合成
        -- -------------------------------------------------------------------
        local t  = clock
        local sA = data.seedA
        local sB = data.seedB

        -- [Layer 1] 主呼吸 sine 波
        --   sA × 微小係数 = 個体ごとの位相オフセット。全結晶が同期するのを防ぐ。
        --   math.sin の引数は既に 2π 倍済みの FREQ_BASE_2PI を使う。
        local wave1 = math.sin(t * FREQ_BASE_2PI + sA * 0.000123)

        -- [Layer 2] Micro-tremor
        --   周波数比が φ² ≈ 2.618（黄金比の2乗）→ 合成波が完全周期を持たない。
        --   AMP_TREMOR を直接乗算してスケールを合わせる。
        local wave2 = math.sin(t * FREQ_TREMOR_2PI + sA * 0.000347)
                    * B.AMP_TREMOR

        -- [Layer 3] Perlin noise 2オクターブ
        --   math.noise(x, y) の戻り値範囲は概ね [-0.5, 0.5]。
        --   第2オクターブは FREQ × φ で非整合かつ周波数を高くして細かい揺らぎを追加。
        --   振幅は 0.5 に下げてオクターブ間のバランスを取る。
        local n1    = math.noise(t * FREQ_NOISE_1,  sA * 0.01)
        local n2    = math.noise(t * FREQ_NOISE_2,  sB * 0.01) * 0.5
        local wave3 = (n1 + n2) * B.AMP_NOISE

        -- 全波形を合成し、influence でスケール
        -- （遠ければ揺らぎも小さく静かに佇む → 近いほど大きく鼓動する）
        local breathWave = (wave1 * B.AMP_BRIGHT + wave2 + wave3) * inf

        -- -------------------------------------------------------------------
        --  STEP 5: PointLight.Brightness に適用
        --
        --  baseBright: FAR ↔ NEAR の線形補間
        --  + breathWave × BRIGHT_SCALE: 呼吸による揺らぎ
        --  + awakePulseBright: 覚醒パルス（一回性）
        -- -------------------------------------------------------------------
        local baseBright = FAR.LightBrightness + DELTA_BRIGHTNESS * inf
        data.light.Brightness = math.max(
            0,
            baseBright + breathWave * B.BRIGHT_SCALE + awakePulseBright
        )

        -- -------------------------------------------------------------------
        --  STEP 6: PointLight.Range に適用（呼吸に合わせて光球が拡縮する）
        --
        --  Range が変化することで「光が広がったり縮んだりする」立体感が生まれる。
        -- -------------------------------------------------------------------
        local baseRange      = FAR.LightRange + DELTA_RANGE * inf
        data.light.Range     = math.max(1, baseRange + breathWave * B.RANGE_SCALE)

        -- -------------------------------------------------------------------
        --  STEP 7: PointLight.Color（影響度で色温度を FAR → NEAR にシフト）
        --
        --  近づくほど光の色が「冷たい暗紫」から「温かい紫白」へ変化する。
        -- -------------------------------------------------------------------
        data.light.Color = lerpColor(FAR.LightColor, NEAR.LightColor, inf)

        -- -------------------------------------------------------------------
        --  STEP 8: Part.Color
        --
        --  ベースカラーを influence で FAR ↔ NEAR 補間したうえで、
        --  HSV の Value（明度）成分のみを呼吸波形で微動させる。
        --  Hue（色相）と Saturation（彩度）は固定するため、
        --  「色が変わる」ではなく「光が内側から揺れる」感覚になる。
        -- -------------------------------------------------------------------
        local baseColor   = lerpColor(FAR.Color, NEAR.Color, inf)
        local ch, cs, cv  = baseColor:ToHSV()
        -- wave1 の低周波成分を色明度に乗せる（wave3 も少量加えてノイズ感を出す）
        local breathV     = (wave1 * B.AMP_COLOR + wave3 * 0.35) * inf
        data.part.Color   = Color3.fromHSV(ch, cs, math.clamp(cv + breathV, 0, 1))

        -- -------------------------------------------------------------------
        --  STEP 9: サーバーへの状態変化通知（クールダウン付き）
        --
        --  influence が閾値を上下するたびにサーバーへ通知し、他のクライアントへ
        --  ブロードキャストさせる。連続送信を防ぐためクールダウンを設ける。
        -- -------------------------------------------------------------------
        if not remotesFolder then continue end

        local cooldownEnd  = remoteFireCooldown[data.part] or 0
        if clock < cooldownEnd then continue end

        local isActive  = data.influence > 0.20
        local wasActive = firedActive[data.part] or false

        if isActive == wasActive then continue end

        local targetRemote = isActive
            and remotesFolder:FindFirstChild(Config.REMOTE_ACTIVATED)
            or  remotesFolder:FindFirstChild(Config.REMOTE_DEACTIVATED)

        if targetRemote and targetRemote:IsA("RemoteEvent") then
            (targetRemote :: RemoteEvent):FireServer(data.part)
            firedActive[data.part]       = isActive
            remoteFireCooldown[data.part] = clock + REMOTE_COOLDOWN
        end
    end
end)

-- ===========================================================================
-- ■ キャラクター再スポーン時のリセット
-- ===========================================================================

local function onCharacterAdded()
    -- 全結晶を FAR 状態に戻す
    for _, data in registry do
        data.influence     = 0
        data.prevInfluence = 0
        data.awakeActive   = false
        data.remoteInf     = 0

        data.light.Brightness = FAR.LightBrightness
        data.light.Range      = FAR.LightRange
        data.light.Color      = FAR.LightColor
        data.part.Color       = FAR.Color
    end

    -- サーバー通知の追跡テーブルをクリア
    firedActive        = {}
    remoteFireCooldown = {}
end

player.CharacterAdded:Connect(onCharacterAdded)
