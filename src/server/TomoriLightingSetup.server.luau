--!strict
-- =============================================================================
--  TomoriLightingSetup  |  Script（Server）
--  ServerScriptService
--
--  責務:
--    ゲーム起動時に Lighting の全設定をコードから適用する。
--    Studio の Properties ウィンドウへの手動設定に依存せず、
--    全設定をバージョン管理下に置くことができる。
--
--  設計の根拠（サーバースクリプトで行う理由）:
--    Lighting の設定はサーバー側で変更するとクライアントへ自動レプリケートされる。
--    したがってサーバースクリプトが最初に1回実行するだけで全プレイヤーに反映される。
--    LocalScript でやると参加するたびにクライアントごとに実行が必要になる。
--
--  ■ 設計コンセプト「灯-Tomori-」
--    「生と死の共存・融合」をテーマとした静謐な薄暗さ。
--    真っ暗ではなく、アメジストや黒曜石のディテールが仄かに浮かぶ空気感。
--    ExposureCompensation を低くすることで Neon 素材の結晶を際立たせる。
-- =============================================================================

local Lighting = game:GetService("Lighting")
local Types    = require(
    game:GetService("ReplicatedStorage")
        :WaitForChild("Tomori", 10)
        :WaitForChild("Types",  10) :: ModuleScript
)

type LightingPreset        = Types.LightingPreset
type AtmospherePreset      = Types.AtmospherePreset
type BloomPreset           = Types.BloomPreset
type ColorCorrectionPreset = Types.ColorCorrectionPreset
type DepthOfFieldPreset    = Types.DepthOfFieldPreset

-- ===========================================================================
-- ■ ヘルパー：既存のエフェクトを削除して新規作成する
--   重複インスタンスを防ぐために必ず既存を削除してから生成する
-- ===========================================================================
local function createEffect(className: string): Instance
    local existing = Lighting:FindFirstChildOfClass(className)
    if existing then existing:Destroy() end
    local inst   = Instance.new(className)
    inst.Parent  = Lighting
    return inst
end

-- ===========================================================================
-- ■ Lighting プロパティ
-- ===========================================================================
-- [Technology: Future]
--   リアルタイムグローバルイルミネーション・ペナンブラシャドウを有効化する。
--   Future は最もコストが高いが、発光結晶が周囲の地面や壁に光を落とすことで
--   「光が空間に存在している」リアリティが生まれる。
--
-- [ClockTime: 19.2]
--   地平線の朱が完全に消えた直後の真の薄暮。
--   太陽は地平線下に没しているため直接光はないが、大気散乱の余韻が残る。
--
-- [ExposureCompensation: -0.9]
--   カメラの露出を強制的に落とすことで、Neon 素材の結晶が周囲から
--   際立って見えるコントラストを作る。最重要パラメータのひとつ。
do
    local preset: LightingPreset = {
        Technology           = Enum.Technology.Future,
        Ambient              = Color3.fromRGB(8,   4,  18),
        OutdoorAmbient       = Color3.fromRGB(16,  9,  32),
        Brightness           = 0.72,
        ClockTime            = 19.2,
        GeographicLatitude   = 35,
        ExposureCompensation = -0.9,
        GlobalShadows        = true,
        ShadowSoftness       = 0.30,
        FogStart             = 45,
        FogEnd               = 240,
        FogColor             = Color3.fromRGB(7,   4,  20),
    }

    Lighting.Technology           = preset.Technology
    Lighting.Ambient              = preset.Ambient
    Lighting.OutdoorAmbient       = preset.OutdoorAmbient
    Lighting.Brightness           = preset.Brightness
    Lighting.ClockTime            = preset.ClockTime
    Lighting.GeographicLatitude   = preset.GeographicLatitude
    Lighting.ExposureCompensation = preset.ExposureCompensation
    Lighting.GlobalShadows        = preset.GlobalShadows
    Lighting.ShadowSoftness       = preset.ShadowSoftness
    Lighting.FogStart             = preset.FogStart
    Lighting.FogEnd               = preset.FogEnd
    Lighting.FogColor             = preset.FogColor
end

-- ===========================================================================
-- ■ Atmosphere
-- ===========================================================================
-- [Color / Decay の関係が空気感の核心]
--   Color  = 近〜中景の大気散乱色（プレイヤー周辺の霞の色）
--   Decay  = 遠景で霧が最も濃くなった先の色（深淵の色）
--   この2色のグラデーションが「美しく霞む奥行き」を作る。
--
-- [Density: 0.50]
--   遠景のディテールが「仄かに」浮かぶ臨界値。
--   これ以上大きくすると中景まで霧で塗り潰されて圧迫感が生じる。
--
-- [Haze: 1.9]
--   地平線方向への霞の拡散量。空間に「果てしなく続く」奥行きを与える。
do
    local preset: AtmospherePreset = {
        Density = 0.50,
        Offset  = 0.22,
        Color   = Color3.fromRGB(82,  60, 130),
        Decay   = Color3.fromRGB(16,   7,  40),
        Glare   = 0.03,
        Haze    = 1.9,
    }

    local atm       = createEffect("Atmosphere") :: Atmosphere
    atm.Density     = preset.Density
    atm.Offset      = preset.Offset
    atm.Color       = preset.Color
    atm.Decay       = preset.Decay
    atm.Glare       = preset.Glare
    atm.Haze        = preset.Haze
end

-- ===========================================================================
-- ■ ColorCorrectionEffect
-- ===========================================================================
-- [Contrast: 0.24]
--   黒曜石の漆黒とアメジストの輝きの差を拡大する。
--   発光結晶が暗闇から「飛び出して見える」コントラストの源泉。
--
-- [Saturation: -0.20]
--   全体の彩度を微かに脱色する。色が若干くすむことで
--   「時間と場所を超えた絵画的な質感」が生まれる。
--   結晶の Neon 発光は自発光なので脱色の影響を受けにくく際立つ。
--
-- [TintColor]
--   全ピクセルに微かなラベンダー（青紫）トーンを乗算する。
--   空間全体の色温度を統一し、「この世界はすべて同じ夜に属している」感を出す。
do
    local preset: ColorCorrectionPreset = {
        Brightness = -0.07,
        Contrast   =  0.24,
        Saturation = -0.20,
        TintColor  = Color3.fromRGB(185, 170, 218),
    }

    local cc        = createEffect("ColorCorrectionEffect") :: ColorCorrectionEffect
    cc.Enabled      = true
    cc.Brightness   = preset.Brightness
    cc.Contrast     = preset.Contrast
    cc.Saturation   = preset.Saturation
    cc.TintColor    = preset.TintColor
end

-- ===========================================================================
-- ■ BloomEffect
-- ===========================================================================
-- [Threshold: 0.88]
--   この輝度以上のピクセルにブルームを適用する。
--   1.0 にすると発光オブジェクト（Neon）だけに掛かるが、0.88 にすることで
--   Neon 素材の輝きが「外側に溢れ出す」より幻想的な表現になる。
--
-- [Size: 32]
--   ブルームの拡散半径。Roblox の BloomEffect は 56 まで設定できるが、
--   大きすぎると隣接オブジェクトに滲みが漏れてノイジーになる。
--   32 が「幻想的」と「クリア」のバランス点。
do
    local preset: BloomPreset = {
        Intensity = 0.65,
        Size      = 32,
        Threshold = 0.88,
    }

    local bloom     = createEffect("BloomEffect") :: BloomEffect
    bloom.Enabled   = true
    bloom.Intensity = preset.Intensity
    bloom.Size      = preset.Size
    bloom.Threshold = preset.Threshold
end

-- ===========================================================================
-- ■ DepthOfFieldEffect
-- ===========================================================================
-- [FarIntensity: 0.22]
--   遠景（FocusDistance 以遠）を微かにぼかす。
--   絵画の「空気遠近法」をカメラエフェクトで再現し、
--   プレイヤーの周囲を焦点として奥行きを強調する。
--
-- [NearIntensity: 0]
--   手前ぼけをゼロにする。手前がぼけると結晶の発光ディテールが見えにくくなる。
--
-- [InFocusRadius: 38]
--   焦点が合う「クリアゾーン」の半径。大きめに取ることで
--   プレイヤー周辺のオブジェクトが確実に鮮明に見える。
do
    local preset: DepthOfFieldPreset = {
        FarIntensity  = 0.22,
        NearIntensity = 0,
        FocusDistance = 30,
        InFocusRadius = 38,
    }

    local dof          = createEffect("DepthOfFieldEffect") :: DepthOfFieldEffect
    dof.Enabled        = true
    dof.FarIntensity   = preset.FarIntensity
    dof.NearIntensity  = preset.NearIntensity
    dof.FocusDistance  = preset.FocusDistance
    dof.InFocusRadius  = preset.InFocusRadius
end
