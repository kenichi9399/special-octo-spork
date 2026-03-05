--!strict
-- =============================================================================
--  CrystalSyncBridge  |  Script（Server）
--  ServerScriptService
--
--  責務:
--    プレイヤーが結晶に近づいたとき、その情報を他の全プレイヤーへ
--    ブロードキャストすることで、「誰かが近くにいる結晶」が他プレイヤーからも
--    微かに光って見えるようにする（マルチプレイヤー体験の共有）。
--
--  ■ 通信フロー
--    1. クライアント（接近者）が FireServer(part) → サーバーへ通知
--    2. サーバーが activeMap にプレイヤーを記録
--    3. サーバーが接近者以外の全クライアントへ FireClient(part) でブロードキャスト
--    4. 他クライアントは data.remoteInf を設定し、薄い発光を表示する
--
--  ■ 安全設計
--    ・RemoteEvent の引数が BasePart でない場合は無視する（クライアント改竄対策）
--    ・activeMap で誰が接近中かを追跡し、「最後の1人が離れたとき」のみ消灯通知
--    ・PlayerRemoving で退出したプレイヤーのエントリを確実にクリーンアップ
--
--  ■ このスクリプトはオプション
--    シングルプレイヤーの体験のみを想定する場合はこのスクリプトを無効化しても
--    TomoriCrystalController.client は正常に動作する（remotesFolder が見つからなければ
--    ローカルのみの発光として機能する）。
-- =============================================================================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(
    ReplicatedStorage:WaitForChild("Tomori", 10)
                     :WaitForChild("Config", 10) :: ModuleScript
)

-- ===========================================================================
-- ■ RemoteEvent フォルダの作成
-- ===========================================================================
-- ServerScriptService のスクリプトはゲーム開始直後に実行されるため、
-- このフォルダはクライアントが参加するより前に存在することが保証される。
local remotesFolder    = Instance.new("Folder")
remotesFolder.Name     = Config.REMOTE_FOLDER_NAME
remotesFolder.Parent   = ReplicatedStorage

local remoteActivated         = Instance.new("RemoteEvent")
remoteActivated.Name          = Config.REMOTE_ACTIVATED
remoteActivated.Parent        = remotesFolder

local remoteDeactivated       = Instance.new("RemoteEvent")
remoteDeactivated.Name        = Config.REMOTE_DEACTIVATED
remoteDeactivated.Parent      = remotesFolder

-- ===========================================================================
-- ■ 状態管理
-- ===========================================================================
-- 「どの Part が誰によってアクティブにされているか」を追跡する。
-- 同じ Part に複数プレイヤーが同時に近づく場合を正しく処理するために必要。
--
-- 構造: { [BasePart]: { [Player]: true } }
local activeMap: { [BasePart]: { [Player]: boolean } } = {}

-- ===========================================================================
-- ■ ユーティリティ
-- ===========================================================================

-- 全クライアントへのブロードキャスト（送信者を除外するオプション付き）
local function broadcastActivated(part: BasePart, excludePlayer: Player?)
    for _, player in Players:GetPlayers() do
        if player ~= excludePlayer then
            remoteActivated:FireClient(player, part)
        end
    end
end

local function broadcastDeactivated(part: BasePart, excludePlayer: Player?)
    for _, player in Players:GetPlayers() do
        if player ~= excludePlayer then
            remoteDeactivated:FireClient(player, part)
        end
    end
end

-- ===========================================================================
-- ■ クライアント → サーバー: 結晶への接近通知
-- ===========================================================================
remoteActivated.OnServerEvent:Connect(function(sender: Player, targetPart: Instance)
    -- 型チェック（RemoteEvent の引数は常に検証する）
    if not targetPart:IsA("BasePart") then return end
    local part = targetPart :: BasePart

    -- activeMap を初期化
    if not activeMap[part] then
        activeMap[part] = {}
    end

    -- 既に登録済みなら何もしない（重複イベント対策）
    if activeMap[part][sender] then return end

    local wasEmpty = (next(activeMap[part]) == nil)
    activeMap[part][sender] = true

    -- この Part への最初の接近者のとき → 他クライアントへブロードキャスト
    if wasEmpty then
        broadcastActivated(part, sender)
    end
end)

-- ===========================================================================
-- ■ クライアント → サーバー: 結晶からの離脱通知
-- ===========================================================================
remoteDeactivated.OnServerEvent:Connect(function(sender: Player, targetPart: Instance)
    if not targetPart:IsA("BasePart") then return end
    local part = targetPart :: BasePart

    -- 登録がなければ無視
    if not activeMap[part] then return end
    if not activeMap[part][sender] then return end

    activeMap[part][sender] = nil

    -- まだ他のプレイヤーが近くにいるなら消灯通知を出さない
    if next(activeMap[part]) then return end

    -- 全員が離れた → テーブルを解放して消灯ブロードキャスト
    activeMap[part] = nil
    broadcastDeactivated(part, sender)
end)

-- ===========================================================================
-- ■ プレイヤー退出時のクリーンアップ
-- ===========================================================================
-- プレイヤーが接近中に切断した場合、activeMap の残留エントリを除去する。
-- これがないと Part が永遠に「誰かが近くにいる」状態のまま残る。
Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
    for part, playerSet in activeMap do
        if not playerSet[leavingPlayer] then continue end

        playerSet[leavingPlayer] = nil

        -- 他にまだ接近中のプレイヤーがいれば消灯しない
        if next(playerSet) then continue end

        -- 全員が離れた（退出を含む）→ 消灯通知
        activeMap[part] = nil
        broadcastDeactivated(part, leavingPlayer)
    end
end)
