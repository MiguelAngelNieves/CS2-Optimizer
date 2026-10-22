<#
  CS2 Optimizer - https://github.com/MiguelAngelNieves/CS2-Optimizer
  Optimiza Counter-Strike 2 tocando SOLO archivos de configuración y ajustes de Windows.
  Nunca modifica archivos del juego ni inyecta nada (seguro con VAC).
  Todo cambio tiene respaldo y se puede revertir con "Restaurar todo".
  Licencia MIT.
#>
param([switch]$Test)
$ErrorActionPreference = 'Continue'
$AppVersion = '0.2.1'

# ---------- Auto-elevar (necesario para límites de CPU/GPU) ----------
if (-not $Test) {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
        exit
    }
}

$Inv = [Globalization.CultureInfo]::InvariantCulture
$Utf8NoBom = New-Object Text.UTF8Encoding $false
$DataRoot = if ($Test) { Join-Path ([IO.Path]::GetTempPath()) 'CS2-Optimizer-test' } else { Join-Path $env:LOCALAPPDATA 'CS2-Optimizer' }
New-Item -ItemType Directory -Force $DataRoot | Out-Null

# =====================================================================
#  Utilidades
# =====================================================================
function Write-NoBom($path, $text) { [IO.File]::WriteAllText($path, $text, $Utf8NoBom) }
function Read-Text($path) { [IO.File]::ReadAllText($path) }
function To-Num($s) {
    if ($null -eq $s) { return $null }
    $d = 0.0
    if ([double]::TryParse(([string]$s).Trim().Replace(',', '.'), [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
    return $null
}
function Fmt($n, $dec = 1) { if ($null -eq $n) { '' } else { ([math]::Round([double]$n, $dec)).ToString($Inv) } }

# Claves tipo  "clave"   "valor"  (cs2_video.txt / vdf simples)
function Get-Key([string]$text, [string]$key) {
    $m = [regex]::Match($text, '"' + [regex]::Escape($key) + '"\s+"([^"]*)"')
    if ($m.Success) { $m.Groups[1].Value } else { $null }
}
function Set-Key([string]$text, [string]$key, [string]$val) {
    $pat = '("' + [regex]::Escape($key) + '"\s+")[^"]*(")'
    if ([regex]::IsMatch($text, $pat)) { return [regex]::Replace($text, $pat, ('${1}' + $val + '${2}')) }
    $i = $text.LastIndexOf('}')
    if ($i -lt 0) { return $text }
    return $text.Substring(0, $i) + "`t`"$key`"`t`t`"$val`"`r`n" + $text.Substring($i)
}

# =====================================================================
#  Detección de Steam / CS2 / cuenta
# =====================================================================
function Find-SteamPath {
    $p = $null
    try { $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -EA Stop).SteamPath } catch {}
    if (-not $p) { try { $p = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -EA Stop).InstallPath } catch {} }
    if ($p) { $p = $p -replace '/', '\' }
    if ($p -and (Test-Path $p)) { return $p }
    foreach ($c in @("${env:ProgramFiles(x86)}\Steam", "$env:ProgramFiles\Steam")) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}
function Get-SteamLibraries([string]$steam) {
    $libs = New-Object System.Collections.Generic.List[string]
    $libs.Add($steam)
    $f = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $f) {
        foreach ($m in [regex]::Matches((Read-Text $f), '"path"\s+"([^"]+)"')) { $libs.Add(($m.Groups[1].Value -replace '\\\\', '\')) }
    }
    $libs | Select-Object -Unique
}
function Find-CS2($libs) {
    foreach ($l in $libs) {
        $acf = Join-Path $l 'steamapps\appmanifest_730.acf'
        if (-not (Test-Path $acf)) { continue }
        $dir = 'Counter-Strike Global Offensive'
        $m = [regex]::Match((Read-Text $acf), '"installdir"\s+"([^"]+)"')
        if ($m.Success) { $dir = $m.Groups[1].Value }
        $g = Join-Path $l "steamapps\common\$dir"
        if (Test-Path (Join-Path $g 'game\bin\win64\cs2.exe')) { return [pscustomobject]@{ Root = $g; Library = $l } }
    }
    return $null
}
function Find-SteamUser([string]$steam) {
    $ud = Join-Path $steam 'userdata'
    $cands = @(Get-ChildItem $ud -Directory -EA SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName '730\local\cfg\cs2_video.txt') })
    if ($cands.Count -eq 0) { return $null }
    $lu = Join-Path $steam 'config\loginusers.vdf'
    if (Test-Path $lu) {
        foreach ($m in [regex]::Matches((Read-Text $lu), '"(\d{17})"\s*\{([^}]*)\}')) {
            if ($m.Groups[2].Value -match '"MostRecent"\s+"1"') {
                $acc = [string]([int64]$m.Groups[1].Value - 76561197960265728)
                $hit = @($cands | Where-Object { $_.Name -eq $acc })
                if ($hit.Count -gt 0) { return $hit[0].FullName }
            }
        }
    }
    ($cands | Sort-Object { (Get-Item (Join-Path $_.FullName '730\local\cfg\cs2_video.txt')).LastWriteTime } -Descending | Select-Object -First 1).FullName
}

# --- Opciones de lanzamiento dentro de localconfig.vdf ---
function Get-AppBlock([string]$t) {
    foreach ($m in [regex]::Matches($t, '(?m)^(\t+)"730"\r?\n\1\{\r?\n')) {
        $ind = $m.Groups[1].Value
        $start = $m.Index + $m.Length
        $close = [regex]::Match($t.Substring($start), "(?m)^$ind\}")
        if (-not $close.Success) { continue }
        $body = $t.Substring($start, $close.Index)
        if ($body -match '"(LastPlayed|LaunchOptions|Playtime|cloud)"') {
            return [pscustomobject]@{ Start = $start; Length = $close.Index; Indent = $ind; Body = $body }
        }
    }
    return $null
}
function Get-LaunchOptions([string]$localcfg) {
    $b = Get-AppBlock (Read-Text $localcfg)
    if (-not $b) { return $null }
    $m = [regex]::Match($b.Body, '"LaunchOptions"\s+"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { return $m.Groups[1].Value } else { return '' }
}
function Set-LaunchOptions([string]$localcfg, [string]$value) {
    $t = Read-Text $localcfg
    $b = Get-AppBlock $t
    if (-not $b) { return $false }
    $re = [regex]'("LaunchOptions"\s+")((?:[^"\\]|\\.)*)(")'
    if ($re.IsMatch($b.Body)) {
        $body = $re.Replace($b.Body, { param($mm) $mm.Groups[1].Value + $value + $mm.Groups[3].Value }, 1)
    } else {
        $body = "$($b.Indent)`t`"LaunchOptions`"`t`t`"$value`"`n" + $b.Body
    }
    Write-NoBom $localcfg ($t.Substring(0, $b.Start) + $body + $t.Substring($b.Start + $b.Length))
    return $true
}
# Mezcla: conserva las opciones del usuario y gestiona solo las nuestras
function Merge-LaunchOptions([string]$current, [bool]$vulkan, [bool]$removeThirdParty) {
    $s = ' ' + $current + ' '
    $s = [regex]::Replace($s, '\s\+exec\s+autoexec(\.cfg)?(?=\s)', ' ')
    $s = [regex]::Replace($s, '\s-vulkan(?=\s)', ' ')
    if ($removeThirdParty) { $s = [regex]::Replace($s, '\s-allow_third_party_software(?=\s)', ' ') }
    $parts = @(($s -split '\s+') | Where-Object { $_ })
    $parts += '+exec'; $parts += 'autoexec'
    if ($vulkan) { $parts += '-vulkan' }
    ($parts -join ' ').Trim()
}

# =====================================================================
#  Escaneo de hardware
# =====================================================================
function Get-GpuTier([string]$name) {
    $n = $name.ToUpper()
    $high = @('RTX\s*20[78]0', 'RTX\s*30[6-9]0', 'RTX\s*40[6-9]0', 'RTX\s*50\d0', 'RX\s*6[6-9]\d0', 'RX\s*7\d{3}', 'RX\s*9\d{3}', 'ARC\s*A7', 'ARC\s*B')
    $mid  = @('RTX\s*2060', 'RTX\s*[345]050', 'GTX\s*10[78]0', 'GTX\s*1660', 'GTX\s*1070', 'RX\s*5[67]00', 'RX\s*5[89]0', 'RX\s*6[56]00', 'ARC\s*A5', 'GTX\s*980')
    foreach ($p in $high) { if ($n -match $p) { return 'alta' } }
    foreach ($p in $mid)  { if ($n -match $p) { return 'media' } }
    return 'baja'
}
function Get-Vendor([string]$name) {
    if ($name -match 'NVIDIA|GeForce|Quadro|RTX|GTX') { 'NVIDIA' } elseif ($name -match 'AMD|Radeon') { 'AMD' } elseif ($name -match 'Intel') { 'Intel' } else { 'Otro' }
}
function Find-NvidiaSmi {
    @("$env:SystemRoot\System32\nvidia-smi.exe", "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
function Get-HardwareScan($gameRoot, $videoPath) {
    $r = [ordered]@{}
    $cs  = Get-CimInstance Win32_ComputerSystem
    $enc = Get-CimInstance Win32_SystemEnclosure -EA SilentlyContinue
    $bat = @(Get-CimInstance Win32_Battery -EA SilentlyContinue)
    $chassisLaptop = @($enc.ChassisTypes | Where-Object { $_ -in 8, 9, 10, 11, 14, 30, 31, 32 }).Count -gt 0
    $r.Equipo   = "$($cs.Manufacturer) $($cs.Model)".Trim()
    $r.Portatil = ($cs.PCSystemType -eq 2) -or ($bat.Count -gt 0) -or $chassisLaptop
    $r.EnBateria = ($bat.Count -gt 0) -and ($bat[0].BatteryStatus -eq 1)
    $os = Get-CimInstance Win32_OperatingSystem
    $r.Windows = "$($os.Caption) (build $($os.BuildNumber))"

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $r.CPU = ($cpu.Name -replace '\s+', ' ').Trim()
    $r.CPU_Nucleos = "$($cpu.NumberOfCores) núcleos / $($cpu.NumberOfLogicalProcessors) hilos"
    $r.CPU_Marca = if ($cpu.Name -match 'AMD') { 'AMD' } else { 'Intel' }

    $gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic Display|Remote|Virtual|Parsec|Mirage|Meta' })
    $dgpu = $gpus | Where-Object { (Get-Vendor $_.Name) -eq 'NVIDIA' } | Select-Object -First 1
    if (-not $dgpu) { $dgpu = $gpus | Where-Object { $_.Name -match 'Radeon.*(RX|Pro|R9|R7|HD)\s' } | Select-Object -First 1 }
    if (-not $dgpu) { $dgpu = $gpus | Where-Object { $_.Name -match 'Arc' } | Select-Object -First 1 }
    if (-not $dgpu) { $dgpu = $gpus | Select-Object -First 1 }
    $r.GPU = $dgpu.Name
    $r.GPU_Marca = Get-Vendor $dgpu.Name
    $r.GPU_Driver = $dgpu.DriverVersion
    $r.GPU_Todas = ($gpus | ForEach-Object { $_.Name }) -join ' + '
    $r.GPU_Nivel = Get-GpuTier $dgpu.Name
    $r.GPU_Integrada = ($dgpu.Name -match 'Radeon\(TM\) Graphics|Radeon Graphics|Vega \d|UHD|Iris|Intel\(R\) HD') -and ($dgpu.Name -notmatch 'RX|Arc')
    $smi = Find-NvidiaSmi
    if ($r.GPU_Marca -eq 'NVIDIA' -and $smi) {
        $v = (& $smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
        if ($v) { $r.GPU_VRAM_GB = Fmt ((To-Num $v) / 1024) 1 }
    }

    $mem = @(Get-CimInstance Win32_PhysicalMemory)
    $total = ($mem | Measure-Object Capacity -Sum).Sum / 1GB
    $r.RAM_GB = Fmt $total 0
    $r.RAM_Modulos = ($mem | ForEach-Object { "$([math]::Round($_.Capacity / 1GB)) GB" }) -join ' + '
    $r.RAM_MTs = [int](($mem | Measure-Object ConfiguredClockSpeed -Maximum).Maximum)
    $r.RAM_MTs_Max = [int](($mem | Measure-Object Speed -Minimum).Minimum)   # velocidad que reportan los módulos (el más lento manda)
    $r.RAM_Velocidad = "$($r.RAM_MTs) MT/s"
    $r.RAM_Canal = if ($mem.Count -ge 2) { 'probablemente doble canal' } else { 'UN SOLO CANAL (rinde menos)' }

    $r.Disco_Juego = 'desconocido'
    try {
        $letter = (Split-Path $gameRoot -Qualifier).TrimEnd(':')
        $part = Get-Partition -DriveLetter $letter -EA Stop
        $pd = Get-PhysicalDisk | Where-Object { $_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
        if ($pd) { $r.Disco_Juego = "$letter`: $($pd.FriendlyName) - $($pd.MediaType) / $($pd.BusType)" }
    } catch {}

    $act = $gpus | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Sort-Object CurrentRefreshRate -Descending | Select-Object -First 1
    $r.Pantalla_Res = if ($act) { "$($act.CurrentHorizontalResolution)x$($act.CurrentVerticalResolution)" } else { '1920x1080' }
    $r.Pantalla_Hz = if ($act -and $act.CurrentRefreshRate -gt 1) { [int]$act.CurrentRefreshRate } else { 60 }

    if ($videoPath -and (Test-Path $videoPath)) {
        $v = Read-Text $videoPath
        $r.CS2_Resolucion = "$(Get-Key $v 'setting.defaultres')x$(Get-Key $v 'setting.defaultresheight')"
        $q = @('setting.shaderquality', 'setting.videocfg_shadow_quality', 'setting.videocfg_texture_detail', 'setting.videocfg_particle_detail', 'setting.videocfg_ao_detail', 'setting.msaa_samples') |
             ForEach-Object { To-Num (Get-Key $v $_) } | Where-Object { $null -ne $_ }
        $r.CS2_Calidad = if (@($q | Where-Object { $_ -gt 0 }).Count -eq 0) { 'mínima' } else { 'media/alta' }
    }
    $r
}
function Get-Recommendation($scan) {
    $res = $scan.Pantalla_Res; $hz = [int]$scan.Pantalla_Hz; $tips = @()
    switch ($scan.GPU_Nivel) {
        'baja'  { $resolution = if ($res -match '^(\d+)x(\d+)$' -and ([double]$matches[1] / [double]$matches[2]) -gt 1.5) { '1600x900' } else { '1280x960' }
                  $quality = 'min'; $fps = if ($scan.Portatil) { [math]::Min($hz, 60) } else { [math]::Min($hz, 90) } }
        'media' { $resolution = $res; $quality = 'min'; $fps = if ($scan.Portatil) { $hz } else { [math]::Min(2 * $hz, 300) } }
        default { $resolution = $res; $quality = 'keep'; $fps = if ($scan.Portatil) { $hz } else { 0 } }
    }
    if ($scan.Portatil) { $tips += 'Portátil: juega con el cargador conectado y en el modo de máximo rendimiento del fabricante.' }
    if ($scan.EnBateria) { $tips += '¡Estás en batería! La GPU rinde mucho menos así.' }
    if ($scan.RAM_Canal -match 'UN SOLO') { $tips += 'RAM en un solo canal: agregar un segundo módulo igual mejora bastante a CS2.' }
    if ($scan.GPU_Integrada) {
        $tips += 'Juegas con la gráfica INTEGRADA: usa la RAM como memoria de video, así que la velocidad de la RAM es clave.'
        if ($scan.RAM_MTs -gt 0 -and $scan.RAM_MTs -lt 3000) {
            $tips += "Tu RAM va a $($scan.RAM_MTs) MT/s. Más velocidad de RAM = más FPS en gráfica integrada, PERO solo si tus módulos la soportan."
            $tips += 'Antes de tocar la BIOS: mira la etiqueta de la RAM (ej. 3200 MHz). Si dice 2400 o no tiene perfil XMP/DOCP, NO lo actives: el PC puede volverse inestable.'
            $tips += 'Si decides probar XMP/DOCP y CS2 se cierra o el PC se reinicia, desactívalo (o restablece la BIOS) de inmediato. Es opcional y bajo tu responsabilidad.'
        }
        $tips += 'Vulkan puede cerrar el juego en algunas gráficas integradas: si pasa, vuelve a DirectX 11.'
    }
    if ($scan.Disco_Juego -match 'HDD') { $tips += 'CS2 está en un disco mecánico (HDD): moverlo a un SSD reduce tirones y cargas.' }
    if ($scan.GPU_Marca -eq 'NVIDIA') { $tips += 'NVIDIA: en el Panel de control, cs2.exe -> Administración de energía: "Preferir rendimiento máximo".' }
    if ($scan.GPU_Todas -match '\+') { $tips += 'Tienes 2 GPUs: en Windows (Configuración > Pantalla > Gráficos) asigna cs2.exe a "Alto rendimiento".' }
    [pscustomobject]@{ Resolution = $resolution; Quality = $quality; Fps = $fps; Tips = $tips }
}

# =====================================================================
#  Ajustes de video / autoexec / energía
# =====================================================================
$QualityMinKeys = [ordered]@{
    'setting.shaderquality' = '0'; 'setting.r_texturefilteringquality' = '0'; 'setting.msaa_samples' = '0'; 'setting.r_csgo_cmaa_enable' = '0'
    'setting.videocfg_shadow_quality' = '0'; 'setting.videocfg_dynamic_shadows' = '0'; 'setting.videocfg_texture_detail' = '0'
    'setting.videocfg_particle_detail' = '0'; 'setting.videocfg_ao_detail' = '0'; 'setting.videocfg_hdr_detail' = '3'
}
function Get-AspectMode([int]$w, [int]$h) {
    $r = $w / $h
    if ([math]::Abs($r - 4 / 3) -lt 0.05) { 0 } elseif ([math]::Abs($r - 16 / 10) -lt 0.05) { 2 } else { 1 }
}
function Build-Autoexec([string]$fps, [bool]$noContrast, [bool]$showFps) {
    $lines = @('// autoexec.cfg - generado por CS2 Optimizer (github.com/MiguelAngelNieves/CS2-Optimizer)',
               "fps_max `"$fps`"", 'fps_max_ui "60"', 'r_show_build_info "0"')
    if ($noContrast) { $lines += 'r_player_visibility_mode "0"' }
    if ($showFps) { $lines += 'cl_hud_telemetry_frametime_show "1"' }
    $lines += 'echo "CS2 Optimizer: autoexec cargado"'
    ($lines -join "`r`n") + "`r`n"
}
function Get-PowerValue([string]$alias) {
    powercfg -attributes SUB_PROCESSOR $alias -ATTRIB_HIDE 2>$null | Out-Null
    $hex = [regex]::Matches((powercfg /q SCHEME_CURRENT SUB_PROCESSOR $alias | Out-String), '0x[0-9a-fA-F]{8}')
    if ($hex.Count -ge 2) { return [Convert]::ToInt32($hex[$hex.Count - 2].Value, 16) }
    return $null
}
function Set-PowerValue([string]$alias, [int]$v) {
    powercfg /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR $alias $v | Out-Null
    powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR $alias $v | Out-Null
}

# =====================================================================
#  Análisis de CSV de HWiNFO (español o inglés)
# =====================================================================
$HwCols = [ordered]@{
    cpu_temp   = @('^Core Max \[.C\]', '^M.ximo de N.cleo \[.C\]', '^CPU \(Tctl/Tdie\) \[.C\]', '^CPU Package \[.C\]', '^CPU Entera \[.C\]')
    cpu_power  = @('^CPU Package Power \[W\]', '^Potencia total de CPU \[W\]', '^CPU PPT \[W\]')
    cpu_mhz    = @('^Core Clocks \(avg\) \[MHz\]', '^Relojes n.cleo \(avg\) \[MHz\]', '^Average Effective Clock')
    cpu_use    = @('^Total CPU Usage \[%\]', '^Uso total de CPU \[%\]')
    throttle   = @('^Core Thermal Throttling \(avg\)', '^Desaceleraci.n t.rmica del n.cleo \(avg\)', '^Thermal Throttling \(HTC\)', '^Desaceleraci.n t.rmica \(HTC\)')
    gpu_temp   = @('^GPU Temperature \[.C\]', '^Temperatura de la GPU \[.C\]')
    gpu_load   = @('^GPU Core Load \[%\]', '^Carga de n.cleo de GPU \[%\]', '^GPU Utilization \[%\]', '^Utilizaci.n de GPU \[%\]', '^GPU D3D Usage \[%\]')
    gpu_power  = @('^GPU Power \[W\]', '^GPU Potencia \[W\]', '^Total Board Power', '^GPU ASIC Power', '^GPU Core Power', '^GPU Potencia del n.cleo')
    fps        = @('^(Framerate|Cuadros por segundo)[^\[]*Presented[^\[]*\(avg\)', '^(Framerate|Cuadros por segundo)[^\[]*\(avg\)', '^(Framerate|Cuadros por segundo)[^\[]*\[FPS\]')
    fps_low    = @('^(Framerate|Cuadros por segundo)[^\[]*Presented[^\[]*1% low', '^(Framerate|Cuadros por segundo)[^\[]*1% low')
}
function Read-HwinfoCsv([string]$path) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($path, [Text.Encoding]::UTF8)
    $p.SetDelimiters(','); $p.HasFieldsEnclosedInQuotes = $true
    $rows = New-Object System.Collections.Generic.List[object]
    while (-not $p.EndOfData) { try { $rows.Add([string[]]$p.ReadFields()) } catch { [void]$p.ReadLine() } }
    $p.Close()
    $len = [int](($rows | Group-Object { $_.Length } | Sort-Object Count -Descending | Select-Object -First 1).Name)
    $headers = @($rows | Where-Object { $_.Length -eq $len -and $_[0] -match 'Date$' })
    $h = if ($headers.Count -gt 0) { $headers[-1] } else { $rows[0] }
    $data = @($rows | Where-Object { $_.Length -eq $len -and $_[0] -match '^\d' })
    [pscustomobject]@{ Header = $h; Data = $data }
}
function Find-Col($header, $patterns) {
    foreach ($pat in $patterns) { for ($i = 0; $i -lt $header.Length; $i++) { if ($header[$i] -match $pat) { return $i } } }
    return -1
}
function Get-Stats($vals) {
    $v = @($vals | Where-Object { $null -ne $_ } | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    [pscustomobject]@{ Avg = ($v | Measure-Object -Average).Average; P95 = $v[[math]::Min($v.Count - 1, [int]($v.Count * 0.95))]; Max = $v[-1] }
}
function Analyze-Hwinfo([string]$path) {
    $csv = Read-HwinfoCsv $path
    $h = $csv.Header; $idx = @{}
    foreach ($k in $HwCols.Keys) { $idx[$k] = Find-Col $h $HwCols[$k] }
    $rows = $csv.Data
    if ($idx.fps -ge 0 -and $idx.gpu_load -ge 0) { $game = @($rows | Where-Object { (To-Num $_[$idx.fps]) -gt 1 -and (To-Num $_[$idx.gpu_load]) -gt 30 }) }
    elseif ($idx.fps -ge 0) { $game = @($rows | Where-Object { (To-Num $_[$idx.fps]) -gt 1 }) }
    elseif ($idx.gpu_load -ge 0) { $game = @($rows | Where-Object { (To-Num $_[$idx.gpu_load]) -gt 5 }) }
    else { $game = $rows }
    if ($game.Count -lt 10) { $game = $rows }
    $out = [ordered]@{ muestras = $game.Count }
    foreach ($k in 'cpu_temp', 'cpu_power', 'cpu_mhz', 'cpu_use', 'gpu_temp', 'gpu_load', 'gpu_power', 'fps', 'fps_low') {
        if ($idx[$k] -lt 0) { continue }
        $i = $idx[$k]
        $s = Get-Stats ($game | ForEach-Object { $n = To-Num $_[$i]; if ($n -gt 0) { $n } })
        if ($s) { $out["${k}_avg"] = Fmt $s.Avg; $out["${k}_max"] = Fmt $s.Max }
    }
    if ($idx.throttle -ge 0) {
        $i = $idx.throttle
        $yes = @($game | Where-Object { $_[$i] -match '^(Yes|S.)$' }).Count
        $out.throttle_pct = Fmt (100 * $yes / [math]::Max(1, $game.Count)) 0
    }
    [pscustomobject]$out
}
function Get-BestRun($rows) {
    $ok = @($rows | Where-Object { (To-Num $_.fps_avg) -gt 0 })
    if ($ok.Count -eq 0) { return $null }
    $maxFps = ($ok | ForEach-Object { To-Num $_.fps_avg } | Measure-Object -Maximum).Maximum
    $ok | Where-Object { (To-Num $_.fps_avg) -ge 0.95 * $maxFps } |
        Sort-Object @{ e = { $t = To-Num $_.cpu_temp_avg; if ($null -eq $t) { 999 } else { $t } } }, @{ e = { -(To-Num $_.fps_avg) } } |
        Select-Object -First 1
}

if ($Test) { return }

# =====================================================================
#  Inicio: detección
# =====================================================================
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$Steam = Find-SteamPath
$Cs2 = if ($Steam) { Find-CS2 (Get-SteamLibraries $Steam) } else { $null }
$UserDir = if ($Steam) { Find-SteamUser $Steam } else { $null }
if (-not $Steam -or -not $Cs2 -or -not $UserDir) {
    [Windows.Forms.MessageBox]::Show("No pude detectar todo lo necesario:`n`nSteam: $Steam`nCS2: $($Cs2.Root)`nCuenta con config de CS2: $UserDir`n`nAbre CS2 al menos una vez y vuelve a intentar.", 'CS2 Optimizer') | Out-Null
    exit
}
$Account   = Split-Path $UserDir -Leaf
$Video     = Join-Path $UserDir '730\local\cfg\cs2_video.txt'
$LocalCfg  = Join-Path $UserDir 'config\localconfig.vdf'
$Autoexec  = Join-Path $Cs2.Root 'game\csgo\cfg\autoexec.cfg'
$Data      = Join-Path $DataRoot $Account
$Backup    = Join-Path $Data 'backups'
$Results   = Join-Path $Data 'resultados'
$StateF    = Join-Path $Data 'estado.json'
$Summary   = Join-Path $Results 'resumen.csv'
$Smi       = Find-NvidiaSmi
New-Item -ItemType Directory -Force $Backup, $Results | Out-Null

# ---- Respaldos originales (solo la primera vez) ----
$OrigVideo = Join-Path $Backup 'cs2_video_ORIGINAL.txt'
if (-not (Test-Path $OrigVideo)) { Copy-Item $Video $OrigVideo }
$OrigAuto = Join-Path $Backup 'autoexec_ORIGINAL.cfg'
$OrigAutoNone = Join-Path $Backup 'autoexec_NO_EXISTIA.txt'
if (-not (Test-Path $OrigAuto) -and -not (Test-Path $OrigAutoNone)) {
    if (Test-Path $Autoexec) { Copy-Item $Autoexec $OrigAuto } else { Set-Content $OrigAutoNone 'no existia' }
}
$OrigMisc = Join-Path $Backup 'otros_ORIGINAL.json'
if (-not (Test-Path $OrigMisc)) {
    $dvrA = $null; $dvrB = $null
    try { $dvrA = (Get-ItemProperty 'HKCU:\System\GameConfigStore' -Name GameDVR_Enabled -EA Stop).GameDVR_Enabled } catch {}
    try { $dvrB = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name AppCaptureEnabled -EA Stop).AppCaptureEnabled } catch {}
    [ordered]@{
        launch = (Get-LaunchOptions $LocalCfg); boost = (Get-PowerValue 'PERFBOOSTMODE'); freqmax = (Get-PowerValue 'PROCFREQMAX')
        throttlemax = (Get-PowerValue 'PROCTHROTTLEMAX'); dvrA = $dvrA; dvrB = $dvrB
    } | ConvertTo-Json | Set-Content $OrigMisc -Encoding UTF8
}
$Orig = Get-Content $OrigMisc -Raw | ConvertFrom-Json

# =====================================================================
#  Interfaz
# =====================================================================
$form = New-Object Windows.Forms.Form
$form.Text = "CS2 Optimizer v$AppVersion"; $form.Size = New-Object Drawing.Size(680, 760)
$form.StartPosition = 'CenterScreen'; $form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Segoe UI', 9)

function New-Ctl($type, $parent, $x, $y, $w, $h) { $c = New-Object "Windows.Forms.$type"; $c.Location = New-Object Drawing.Point($x, $y); if ($w) { $c.Width = $w }; if ($h) { $c.Height = $h }; $parent.Controls.Add($c); $c }
function Add-Label($p, $t, $x, $y) { $l = New-Ctl 'Label' $p $x $y; $l.Text = $t; $l.AutoSize = $true; $l }
function Add-Combo($p, $items, $x, $y, $w) { $c = New-Ctl 'ComboBox' $p $x $y $w; $c.DropDownStyle = 'DropDownList'; foreach ($i in $items) { [void]$c.Items.Add($i) }; if ($c.Items.Count) { $c.SelectedIndex = 0 }; $c }
function Add-Check($p, $t, $x, $y) { $c = New-Ctl 'CheckBox' $p $x $y; $c.Text = $t; $c.AutoSize = $true; $c }
function Add-Button($p, $t, $x, $y, $w) { $b = New-Ctl 'Button' $p $x $y $w 30; $b.Text = $t; $b }
function Add-Group($p, $t, $x, $y, $w, $h) { $g = New-Ctl 'GroupBox' $p $x $y $w $h; $g.Text = $t; $g }

$tabs = New-Ctl 'TabControl' $form 8 8 650 470
$tScan = New-Object Windows.Forms.TabPage; $tScan.Text = '1. Escaneo'
$tSet  = New-Object Windows.Forms.TabPage; $tSet.Text = '2. Ajustes'
$tTest = New-Object Windows.Forms.TabPage; $tTest.Text = '3. Medir y comparar'
$tabs.TabPages.AddRange(@($tScan, $tSet, $tTest))

$tbLog = New-Ctl 'TextBox' $form 8 485 650 230
$tbLog.Multiline = $true; $tbLog.ScrollBars = 'Vertical'; $tbLog.ReadOnly = $true; $tbLog.Font = New-Object Drawing.Font('Consolas', 9)
function Log($m) { $tbLog.AppendText("[$(Get-Date -Format HH:mm:ss)] $m`r`n") }

# ---------------- Pestaña 1: Escaneo ----------------
$tbScan = New-Ctl 'TextBox' $tScan 8 8 625 380
$tbScan.Multiline = $true; $tbScan.ScrollBars = 'Vertical'; $tbScan.ReadOnly = $true; $tbScan.Font = New-Object Drawing.Font('Consolas', 9)
$bRescan = Add-Button $tScan 'Escanear de nuevo' 8 398 150
$bRecommend = Add-Button $tScan 'Usar recomendación  ->' 168 398 190
$bRecommend.BackColor = [Drawing.Color]::FromArgb(46, 125, 50); $bRecommend.ForeColor = 'White'

# ---------------- Pestaña 2: Ajustes ----------------
$g1 = Add-Group $tSet 'Gráficos (con CS2 cerrado)' 8 6 625 150
Add-Label $g1 'Resolución:' 10 25 | Out-Null
$cbRes = Add-Combo $g1 @() 120 22 260
Add-Label $g1 'Calidad:' 10 57 | Out-Null
$cbQual = Add-Combo $g1 @('No tocar (la que tengas)', 'Mínimo competitivo (todo bajo)') 120 54 260
Add-Label $g1 'API gráfica:' 10 89 | Out-Null
$cbApi = Add-Combo $g1 @('DirectX 11 (normal)', 'Vulkan (-vulkan, experimental)') 120 86 260
$chkFsr = Add-Check $g1 'FSR "Rendimiento" (más FPS, imagen más suave/borrosa)' 10 118

$g2 = Add-Group $tSet 'Juego (autoexec + opciones de lanzamiento)' 8 160 625 120
Add-Label $g2 'Límite FPS:' 10 25 | Out-Null
$cbFps = Add-Combo $g2 @('0 (sin límite)', '30', '45', '60', '75', '90', '120', '144', '165', '200', '240', '300') 120 22 130
$chkVis = Add-Check $g2 'Quitar "contraste de jugadores" (un poco más de FPS)' 270 24
$chkShowFps = Add-Check $g2 'Mostrar FPS siempre en pantalla' 10 55
$chkThird = Add-Check $g2 'Quitar -allow_third_party_software (recomendado)' 270 55
Add-Label $g2 'Las opciones de lanzamiento solo se cambian con Steam cerrado. Se conservan las tuyas.' 10 88 | Out-Null

$g3 = Add-Group $tSet 'Sistema (calor / energía)' 8 284 625 120
Add-Label $g3 'CPU:' 10 25 | Out-Null
$cbCpu = Add-Combo $g3 @('Normal (con turbo)', 'Sin turbo (menos calor)', 'Tope 3.0 GHz', 'Tope 3.5 GHz') 120 22 220
Add-Label $g3 'Reloj GPU máx:' 10 57 | Out-Null
$cbGpu = Add-Combo $g3 @('Sin límite', '1800 MHz', '1500 MHz', '1300 MHz', '1100 MHz') 120 54 220
$lblGpu = Add-Label $g3 '(solo NVIDIA, se reinicia al apagar)' 350 57
$chkDvr = Add-Check $g3 'Desactivar grabación en segundo plano de Xbox Game Bar' 10 88

$bApply   = Add-Button $tSet 'APLICAR' 8 410 150
$bRestore = Add-Button $tSet 'Restaurar todo' 168 410 150
$bCache   = Add-Button $tSet 'Limpiar caché shaders' 328 410 150
$bPlay    = Add-Button $tSet 'Abrir CS2' 488 410 145
$bApply.BackColor = [Drawing.Color]::FromArgb(46, 125, 50); $bApply.ForeColor = 'White'

# ---------------- Pestaña 3: Medir ----------------
$g4 = Add-Group $tTest 'Medición con HWiNFO (recomendado: temperaturas reales y FPS)' 8 6 625 140
Add-Label $g4 "1) Abre HWiNFO64 -> Sensores -> botón verde '+' (registro) -> guarda el CSV.`n2) Juega 10 min. 3) Detén el registro. 4) Analízalo aquí:" 10 22 | Out-Null
Add-Label $g4 'Nombre de la prueba:' 10 68 | Out-Null
$tbLabel = New-Ctl 'TextBox' $g4 140 65 200
Add-Label $g4 'Notas:' 350 68 | Out-Null
$tbNotes = New-Ctl 'TextBox' $g4 395 65 220
$bAnalyze = Add-Button $g4 'Analizar CSV de HWiNFO...' 10 98 200
$bAnalyze.BackColor = [Drawing.Color]::FromArgb(46, 125, 50); $bAnalyze.ForeColor = 'White'
$bHwinfo = Add-Button $g4 'Descargar HWiNFO' 220 98 140

$g5 = Add-Group $tTest 'Comparación de pruebas' 8 150 625 240
$tbReport = New-Ctl 'TextBox' $g5 10 20 605 210
$tbReport.Multiline = $true; $tbReport.ScrollBars = 'Both'; $tbReport.WordWrap = $false; $tbReport.ReadOnly = $true; $tbReport.Font = New-Object Drawing.Font('Consolas', 8.5)
$bOpen = Add-Button $tTest 'Abrir carpeta de resultados' 8 398 200
$bExport = Add-Button $tTest 'Exportar diagnóstico (.zip)' 218 398 200

# =====================================================================
#  Lógica
# =====================================================================
$script:Scan = $null; $script:Rec = $null

function Fill-Resolutions($native) {
    $cbRes.Items.Clear()
    $list = @($native, '1920x1080', '1600x900', '1440x1080', '1280x960', '1280x720', '1024x768') | Select-Object -Unique
    foreach ($r in $list) {
        if ($r -match '^(\d+)x(\d+)$') {
            $ar = switch (Get-AspectMode ([int]$matches[1]) ([int]$matches[2])) { 0 { '4:3' } 1 { '16:9' } 2 { '16:10' } }
            $tag = if ($r -eq $native) { ', nativa' } else { '' }
            [void]$cbRes.Items.Add("$r ($ar$tag)")
        }
    }
    $cbRes.SelectedIndex = 0
}
function Select-Res($res) { for ($i = 0; $i -lt $cbRes.Items.Count; $i++) { if ($cbRes.Items[$i] -like "$res *") { $cbRes.SelectedIndex = $i; return } } }
function Select-Fps($fps) {
    $txt = if ([int]$fps -eq 0) { '0 (sin límite)' } else { [string]$fps }
    if (-not $cbFps.Items.Contains($txt)) { [void]$cbFps.Items.Add($txt) }
    $cbFps.SelectedItem = $txt
}
function Do-Scan {
    Log 'Escaneando equipo...'
    $script:Scan = Get-HardwareScan $Cs2.Root $Video
    $script:Rec = Get-Recommendation $script:Scan
    $s = $script:Scan; $r = $script:Rec
    $txt = New-Object Text.StringBuilder
    [void]$txt.AppendLine("=== TU EQUIPO ===")
    foreach ($k in $s.Keys) { [void]$txt.AppendLine(("{0,-16} {1}" -f $k, $s[$k])) }
    [void]$txt.AppendLine("")
    [void]$txt.AppendLine("=== CS2 DETECTADO ===")
    [void]$txt.AppendLine("Juego:    $($Cs2.Root)")
    [void]$txt.AppendLine("Cuenta:   $Account")
    [void]$txt.AppendLine("Lanzam.:  $(Get-LaunchOptions $LocalCfg)")
    [void]$txt.AppendLine("")
    [void]$txt.AppendLine("=== RECOMENDACIÓN (GPU nivel $($s.GPU_Nivel)$(if($s.Portatil){', portátil'})) ===")
    [void]$txt.AppendLine("Resolución: $($r.Resolution)")
    [void]$txt.AppendLine("Calidad:    $(if($r.Quality -eq 'min'){'mínimo competitivo'}else{'la que tengas'})")
    [void]$txt.AppendLine("Límite FPS: $(if($r.Fps -eq 0){'sin límite'}else{$r.Fps})")
    if ($r.Tips.Count) { [void]$txt.AppendLine(""); [void]$txt.AppendLine("=== CONSEJOS ==="); foreach ($t in $r.Tips) { [void]$txt.AppendLine("- $t") } }
    $tbScan.Text = $txt.ToString()
    $txt.ToString() | Set-Content (Join-Path $Results 'escaneo.txt') -Encoding UTF8
    if ($cbRes.Items.Count -eq 0) { Fill-Resolutions $s.Pantalla_Res }
    $isNv = ($s.GPU_Marca -eq 'NVIDIA') -and $Smi
    $cbGpu.Enabled = [bool]$isNv; $lblGpu.Enabled = [bool]$isNv
    Log "Listo: $($s.CPU) | $($s.GPU) | $($s.RAM_GB) GB"
}
function Get-UiState {
    [ordered]@{ res = $cbRes.SelectedItem; qual = $cbQual.SelectedIndex; api = $cbApi.SelectedIndex; fsr = $chkFsr.Checked; fps = $cbFps.SelectedItem
                vis = $chkVis.Checked; showfps = $chkShowFps.Checked; third = $chkThird.Checked; cpu = $cbCpu.SelectedIndex; gpu = $cbGpu.SelectedIndex; dvr = $chkDvr.Checked }
}
function Load-UiState {
    if (-not (Test-Path $StateF)) { return $false }
    try { $st = Get-Content $StateF -Raw | ConvertFrom-Json } catch { return $false }
    if ($st.res -and $cbRes.Items.Contains($st.res)) { $cbRes.SelectedItem = $st.res }
    $cbQual.SelectedIndex = [int]$st.qual; $cbApi.SelectedIndex = [int]$st.api; $chkFsr.Checked = $st.fsr
    if ($st.fps) { if (-not $cbFps.Items.Contains($st.fps)) { [void]$cbFps.Items.Add($st.fps) }; $cbFps.SelectedItem = $st.fps }
    $chkVis.Checked = $st.vis; $chkShowFps.Checked = $st.showfps; $chkThird.Checked = $st.third
    $cbCpu.SelectedIndex = [int]$st.cpu; $cbGpu.SelectedIndex = [int]$st.gpu; $chkDvr.Checked = $st.dvr
    return $true
}
function Apply-Recommendation {
    $r = $script:Rec
    Select-Res $r.Resolution
    $cbQual.SelectedIndex = if ($r.Quality -eq 'min') { 1 } else { 0 }
    Select-Fps $r.Fps
    $chkVis.Checked = $true; $chkShowFps.Checked = $true; $chkThird.Checked = $true
    $tabs.SelectedTab = $tSet
    Log 'Recomendación cargada en "Ajustes". Revisa y presiona APLICAR.'
}

function Apply-Video {
    $t = Read-Text $Video
    if ($cbRes.SelectedItem -match '^(\d+)x(\d+)') {
        $w = [int]$matches[1]; $h = [int]$matches[2]
        $t = Set-Key $t 'setting.defaultres' $w; $t = Set-Key $t 'setting.defaultresheight' $h
        $t = Set-Key $t 'setting.aspectratiomode' (Get-AspectMode $w $h)
    }
    $t = Set-Key $t 'setting.videocfg_fsr_detail' $(if ($chkFsr.Checked) { '4' } else { '0' })
    if ($cbQual.SelectedIndex -eq 1) { foreach ($k in $QualityMinKeys.Keys) { $t = Set-Key $t $k $QualityMinKeys[$k] } }
    if ($script:Scan.GPU_Marca -eq 'NVIDIA') { $t = Set-Key $t 'setting.r_low_latency' '1' }
    Write-NoBom $Video $t
    Log "Video: $($cbRes.SelectedItem), calidad=$($cbQual.SelectedItem), FSR=$($chkFsr.Checked)"
}
function Apply-Autoexec {
    $fps = ($cbFps.SelectedItem -split ' ')[0]
    $content = Build-Autoexec $fps $chkVis.Checked $chkShowFps.Checked
    if (Test-Path $OrigAuto) {
        # El usuario tenía su propio autoexec: conservamos lo suyo y añadimos lo nuestro al final
        $content = (Read-Text $OrigAuto).TrimEnd() + "`r`n`r`n// ---- CS2 Optimizer ----`r`n" + $content
    }
    Write-NoBom $Autoexec $content
    Log "autoexec: fps_max $fps"
}
function Apply-Launch {
    if (Get-Process steam -EA SilentlyContinue) {
        Log 'Steam está abierto: NO cambié las opciones de lanzamiento. Cierra Steam y presiona APLICAR otra vez.'
        [Windows.Forms.MessageBox]::Show("Steam está abierto, así que NO pude cambiar las opciones de lanzamiento (+exec autoexec / Vulkan).`n`nLo demás sí se aplicó. Cierra Steam por completo (ícono junto al reloj > Salir) y presiona APLICAR otra vez.", 'CS2 Optimizer') | Out-Null
        return
    }
    $cur = Get-LaunchOptions $LocalCfg
    if ($null -eq $cur) { Log 'No encontré CS2 en localconfig.vdf: pon "+exec autoexec" a mano en Steam > CS2 > Propiedades.'; return }
    $new = Merge-LaunchOptions $cur ($cbApi.SelectedIndex -eq 1) $chkThird.Checked
    if (Set-LaunchOptions $LocalCfg $new) { Log "Opciones de lanzamiento: $new" }
}
function Apply-System {
    $b = if ($null -ne $Orig.boost) { [int]$Orig.boost } else { 2 }
    switch ($cbCpu.SelectedIndex) { 0 { $boost = $b; $freq = 0 } 1 { $boost = 0; $freq = 0 } 2 { $boost = $b; $freq = 3000 } 3 { $boost = $b; $freq = 3500 } }
    Set-PowerValue 'PROCTHROTTLEMAX' 100; Set-PowerValue 'PERFBOOSTMODE' $boost; Set-PowerValue 'PROCFREQMAX' $freq
    powercfg /setactive SCHEME_CURRENT | Out-Null
    Log "CPU: $($cbCpu.SelectedItem) (verificado: turbo=$(Get-PowerValue 'PERFBOOSTMODE'), tope=$(Get-PowerValue 'PROCFREQMAX') MHz)"
    if ($cbGpu.Enabled -and $Smi) {
        $o = if ($cbGpu.SelectedIndex -eq 0) { & $Smi -rgc 2>&1 } else { & $Smi -lgc "300,$(($cbGpu.SelectedItem -split ' ')[0])" 2>&1 }
        Log "GPU: $($cbGpu.SelectedItem) -> $(($o | Out-String).Trim())"
    }
    if ($chkDvr.Checked) {
        New-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Force -EA SilentlyContinue | Out-Null
        Set-ItemProperty 'HKCU:\System\GameConfigStore' GameDVR_Enabled 0 -Type DWord
        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled 0 -Type DWord
        Log 'Game DVR desactivado'
    } else { Restore-Dvr }
}
function Restore-Dvr {
    if ($null -ne $Orig.dvrA) { Set-ItemProperty 'HKCU:\System\GameConfigStore' GameDVR_Enabled ([int]$Orig.dvrA) -Type DWord }
    if ($null -ne $Orig.dvrB) { Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled ([int]$Orig.dvrB) -Type DWord }
}

function Refresh-Report {
    if (-not (Test-Path $Summary)) { $tbReport.Text = 'Aún no hay pruebas. Analiza un CSV de HWiNFO para empezar.'; return }
    $rows = @(Import-Csv $Summary)
    $fmt = '{0,-16} {1,-12} {2,-5} {3,-12} {4,6} {5,6} {6,7} {7,7} {8,7} {9,6}'
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine(($fmt -f 'Prueba', 'Resolución', 'FPSc', 'CPU', 'FPS', '1%low', 'CPU°C', 'CPUmax', 'Throt%', 'GPU°C'))
    foreach ($r in $rows) {
        [void]$sb.AppendLine(($fmt -f ([string]$r.prueba).PadRight(16).Substring(0, 16), ([string]$r.resolucion -split ' ')[0], $r.fps_cap, ([string]$r.cpu).PadRight(12).Substring(0, 12), $r.fps_avg, $r.fps_low_avg, $r.cpu_temp_avg, $r.cpu_temp_max, $r.throttle_pct, $r.gpu_temp_avg))
    }
    $best = Get-BestRun $rows
    if ($best) { [void]$sb.AppendLine(''); [void]$sb.AppendLine("MEJOR EQUILIBRIO: '$($best.prueba)' (FPS altos con la CPU más fresca)") }
    $tbReport.Text = $sb.ToString()
}

# ---------------- Eventos ----------------
$bRescan.Add_Click({ Do-Scan })
$bRecommend.Add_Click({ if (-not $script:Rec) { Do-Scan }; Apply-Recommendation })

$bApply.Add_Click({
    if (Get-Process cs2 -EA SilentlyContinue) { [Windows.Forms.MessageBox]::Show('Cierra CS2 antes de aplicar (el juego sobrescribe su configuración al salir).', 'CS2 Optimizer') | Out-Null; return }
    try { Apply-Video; Apply-Autoexec; Apply-Launch; Apply-System
          Get-UiState | ConvertTo-Json | Set-Content $StateF -Encoding UTF8
          Log '--- Listo. Abre CS2 y prueba. ---' } catch { Log "ERROR: $_" }
})
$bRestore.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('¿Volver todo a como estaba antes de CS2 Optimizer?', 'Restaurar', 'YesNo') -ne 'Yes') { return }
    try {
        Copy-Item $OrigVideo $Video -Force; Log 'Video original restaurado'
        if (Test-Path $OrigAuto) { Copy-Item $OrigAuto $Autoexec -Force; Log 'autoexec original restaurado' }
        elseif (Test-Path $Autoexec) { Move-Item $Autoexec "$Autoexec.desactivado" -Force; Log 'autoexec desactivado' }
        if ($null -ne $Orig.boost) { Set-PowerValue 'PERFBOOSTMODE' ([int]$Orig.boost) }
        Set-PowerValue 'PROCFREQMAX' $(if ($null -ne $Orig.freqmax) { [int]$Orig.freqmax } else { 0 })
        Set-PowerValue 'PROCTHROTTLEMAX' $(if ($null -ne $Orig.throttlemax) { [int]$Orig.throttlemax } else { 100 })
        powercfg /setactive SCHEME_CURRENT | Out-Null; Log 'Energía de CPU restaurada'
        if ($Smi) { & $Smi -rgc 2>&1 | Out-Null; Log 'Reloj de GPU sin límite' }
        Restore-Dvr
        if (Get-Process steam -EA SilentlyContinue) { Log 'Steam abierto: cierra Steam y presiona Restaurar otra vez para devolver las opciones de lanzamiento.' }
        elseif ($null -ne $Orig.launch) { [void](Set-LaunchOptions $LocalCfg ([string]$Orig.launch)); Log "Opciones de lanzamiento: '$($Orig.launch)'" }
        Remove-Item $StateF -EA SilentlyContinue
        Log '--- Todo restaurado ---'
    } catch { Log "ERROR: $_" }
})
$bCache.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('¿Borrar cachés de shaders? La primera partida después irá algo trabada mientras se reconstruyen.', 'Caché', 'YesNo') -ne 'Yes') { return }
    foreach ($p in @((Join-Path $Cs2.Library 'steamapps\shadercache\730'), "$env:LOCALAPPDATA\NVIDIA\DXCache", "$env:LOCALAPPDATA\NVIDIA\GLCache",
                     "$env:LOCALAPPDATA\AMD\DxCache", "$env:LOCALAPPDATA\AMD\DxcCache", "$env:LOCALAPPDATA\AMD\VkCache", "$env:LOCALAPPDATA\D3DSCache")) {
        if (Test-Path $p) { Get-ChildItem $p -Force | Remove-Item -Recurse -Force -EA SilentlyContinue; Log "Limpiado: $p" }
    }
})
$bPlay.Add_Click({ Start-Process 'steam://rungameid/730' })
$bOpen.Add_Click({ Start-Process explorer.exe $Results })
$bHwinfo.Add_Click({ Start-Process 'https://www.hwinfo.com/download/' })

$bAnalyze.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = 'CSV de HWiNFO (*.csv)|*.csv'; $dlg.InitialDirectory = $Results
    if ($dlg.ShowDialog() -ne 'OK') { return }
    try {
        Log "Analizando $(Split-Path $dlg.FileName -Leaf)..."
        $a = Analyze-Hwinfo $dlg.FileName
        $label = if ($tbLabel.Text) { $tbLabel.Text } else { 'prueba ' + (Get-Date -Format 'MMdd-HHmm') }
        $ap = $null; if (Test-Path $StateF) { try { $ap = Get-Content $StateF -Raw | ConvertFrom-Json } catch {} }
        if ($ap) { $resA = $ap.res; $fpsA = $ap.fps; $apiA = $cbApi.Items[[int]$ap.api]; $cpuA = $cbCpu.Items[[int]$ap.cpu]; $gpuA = $cbGpu.Items[[int]$ap.gpu] }
        else { $resA = 'original (sin aplicar)'; $fpsA = '-'; $apiA = '-'; $cpuA = '-'; $gpuA = '-' }
        $rec = [ordered]@{ fecha = (Get-Date -Format 'yyyy-MM-dd HH:mm'); prueba = $label; resolucion = $resA; fps_cap = $fpsA
                           api = $apiA; cpu = $cpuA; gpu_cap = $gpuA; notas = $tbNotes.Text; archivo = (Split-Path $dlg.FileName -Leaf) }
        foreach ($k in 'muestras', 'fps_avg', 'fps_low_avg', 'cpu_temp_avg', 'cpu_temp_max', 'throttle_pct', 'cpu_power_avg', 'cpu_mhz_avg', 'cpu_use_avg', 'gpu_temp_avg', 'gpu_temp_max', 'gpu_load_avg', 'gpu_power_avg') {
            $rec[$k] = if ($a.PSObject.Properties[$k]) { $a.$k } else { '' }
        }
        [pscustomobject]$rec | Export-Csv $Summary -Append -NoTypeInformation -Encoding UTF8 -Force
        $dest = Join-Path $Results (Split-Path $dlg.FileName -Leaf)
        if ($dlg.FileName -ne $dest) { Copy-Item $dlg.FileName $dest -Force -EA SilentlyContinue }
        Log ("{0}: FPS {1} (1% low {2}) | CPU {3}°C (máx {4}, throttling {5}%) | GPU {6}°C" -f $label, $rec.fps_avg, $rec.fps_low_avg, $rec.cpu_temp_avg, $rec.cpu_temp_max, $rec.throttle_pct, $rec.gpu_temp_avg)
        $tbLabel.Text = ''; $tbNotes.Text = ''
        Refresh-Report
    } catch { Log "ERROR analizando: $_" }
})
$bExport.Add_Click({
    $zip = Join-Path ([Environment]::GetFolderPath('Desktop')) ("CS2-Optimizer-diagnostico-{0}.zip" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
    try {
        $files = @(Get-ChildItem $Results -File | ForEach-Object { $_.FullName }) + @($StateF) | Where-Object { Test-Path $_ }
        Compress-Archive -Path $files -DestinationPath $zip -Force
        Log "Diagnóstico guardado en el Escritorio: $(Split-Path $zip -Leaf)"
        Start-Process explorer.exe "/select,`"$zip`""
    } catch { Log "ERROR exportando: $_" }
})

# ---------------- Arranque ----------------
Log "CS2 Optimizer v$AppVersion | Steam: $Steam | CS2: $($Cs2.Root) | cuenta $Account"
Log "Datos y respaldos: $Data"
Do-Scan
if (-not (Load-UiState)) { Apply-Recommendation; $tabs.SelectedTab = $tScan }
Refresh-Report
[void]$form.ShowDialog()
