param(
    [string]$LuatoolsPath = "D:\\Luatools\\Luatools_v3.exe"
)

$ErrorActionPreference = "Stop"
$projectDir = $PSScriptRoot
$required = @("main.lua", "config.lua", "gnss.lua", "motion.lua", "alerts.lua", "geofence.lua", "spool.lua", "mqtt_upload.lua", "protocol.lua")

foreach ($name in $required) {
    $path = Join-Path $projectDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "缺少固件文件: $path"
    }
}

$configText = Get-Content -LiteralPath (Join-Path $projectDir "config.lua") -Raw
if ($configText -match 'CHANGE_ME') {
    throw "请先编辑 config.lua，填写 MQTT host/username/password。"
}

if (-not (Test-Path -LiteralPath $LuatoolsPath -PathType Leaf)) {
    throw "未找到 LuaTools: $LuatoolsPath。请用 -LuatoolsPath 指定 Luatools_v3.exe。"
}

Write-Host "固件目录校验通过: $projectDir"
Write-Host "LuaTools 中请选择 Air780EGG 的 LuatOS .soc，加入以上 $($required.Count) 个 Lua 文件（含 geofence.lua），并勾选添加默认 lib。"
Write-Host "首次烧录选‘下载底层和脚本’；底层未变时可选‘下载脚本’。"
Start-Process -FilePath $LuatoolsPath -WorkingDirectory (Split-Path -Parent $LuatoolsPath)
