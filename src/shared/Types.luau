--!strict
--------------------------------------------------------------------------------
--  Types  |  ModuleScript
--  ReplicatedStorage > Tomori > Types
--
--  「灯-Tomori-」システム全体で共有する型定義。
--  --!strict モードで型安全を保証するために全スクリプトがここを参照する。
--------------------------------------------------------------------------------

local Types = {}

-- ===========================================================================
-- ■ クリスタル1個の実行時状態
-- ===========================================================================
export type CrystalData = {
    -- 対象の BasePart
    part          : BasePart,

    -- 管理する PointLight（なければ初期化時に生成される）
    light         : PointLight,

    -- 現在の平滑化済み影響度 [0.0, 1.0]
    -- 0 = 完全に遠方（FAR 状態）
    -- 1 = 完全に近接（NEAR 状態）
    influence     : number,

    -- 前フレームの影響度（覚醒パルスの Rising Edge 検出に使用）
    prevInfluence : number,

    -- Perlin noise の個体差シード（各 Crystal に固有の揺らぎを与える）
    seedA         : number,   -- 主シード（x 軸オフセット）
    seedB         : number,   -- 第2オクターブ用シード（y 軸オフセット）

    -- 覚醒パルスの管理
    awakeAt       : number,   -- 覚醒が発火した時刻（clock 基準）
    awakeActive   : boolean,  -- パルスが進行中かどうか

    -- 他プレイヤーの接近によって加算される影響度 [0.0, 1.0]
    remoteInf     : number,
}

-- ===========================================================================
-- ■ Lighting 設定値の構造体（TomoriLightingSetup が使用）
-- ===========================================================================
export type LightingPreset = {
    Technology           : Enum.Technology,
    Ambient              : Color3,
    OutdoorAmbient       : Color3,
    Brightness           : number,
    ClockTime            : number,
    GeographicLatitude   : number,
    ExposureCompensation : number,
    GlobalShadows        : boolean,
    ShadowSoftness       : number,
    FogStart             : number,
    FogEnd               : number,
    FogColor             : Color3,
}

export type AtmospherePreset = {
    Density : number,
    Offset  : number,
    Color   : Color3,
    Decay   : Color3,
    Glare   : number,
    Haze    : number,
}

export type BloomPreset = {
    Intensity : number,
    Size      : number,
    Threshold : number,
}

export type ColorCorrectionPreset = {
    Brightness : number,
    Contrast   : number,
    Saturation : number,
    TintColor  : Color3,
}

export type DepthOfFieldPreset = {
    FarIntensity  : number,
    NearIntensity : number,
    FocusDistance : number,
    InFocusRadius : number,
}

-- ===========================================================================

return table.freeze(Types)
