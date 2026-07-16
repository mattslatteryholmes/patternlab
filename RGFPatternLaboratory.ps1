#requires -version 5.1

# RGF Pattern Laboratory version 8.2
# Native Windows engine: no WSL or Ubuntu is required.
# Statistics distributions and generalized classical/consecutive/vincular pattern tools.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Numerics
try { Add-Type -AssemblyName System.Net.Http } catch { }
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:EnginePath = Join-Path $script:AppDirectory 'PatternEngine.exe'
$script:RunningProcess = $null
$script:CurrentOperation = ''
$script:CurrentLogPath = ''
$script:CurrentErrorLogPath = ''
$script:CurrentScriptPath = ''
$script:CurrentShowLog = $true
$script:LastLogLength = -1
$script:LastErrorLogLength = -1
$script:RunStarted = $null

$sessionBase = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:TEMP } else { $env:LOCALAPPDATA }
$script:SessionRoot = Join-Path $sessionBase ('PatternLaboratory\RGF_Session_' + $PID + '_' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Force -Path $script:SessionRoot)
$script:CurrentRunDirectory = ''
$script:CurrentOutputPrefix = ''
$script:CurrentClassFile = ''
$script:CurrentCatalogDirectory = ''
$script:CurrentStoreAll = $false
$script:CurrentOnlyK = 0
$script:CurrentClassText = ''
$script:CurrentClasses = @()
$script:TotalsDataTable = $null
$script:ByMaxDataTable = $null
$script:TotalsDisplayDataTable = $null
$script:OeisFooterRow = $null
$script:OeisLookupQueue = New-Object System.Collections.Queue
$script:OeisActiveLookup = $null
$script:OeisLookupGeneration = 0
$script:OeisResultsByColumn = @{}
$script:OeisCache = @{}
$script:OeisLookupTimer = $null
$script:OeisHttpClient = $null
try {
    $script:OeisHttpClient = New-Object System.Net.Http.HttpClient
    $script:OeisHttpClient.Timeout = [TimeSpan]::FromSeconds(12)
    $script:OeisHttpClient.DefaultRequestHeaders.UserAgent.ParseAdd('PatternLaboratory/8.2')
    $script:OeisHttpClient.DefaultRequestHeaders.Accept.ParseAdd('application/json')
} catch { $script:OeisHttpClient = $null }

$script:PendingListPage = $null
$script:ListState = $null
$script:ListForm = $null
$script:ListItems = $null
$script:ListStatus = $null
$script:ListPreviousButton = $null
$script:ListNextButton = $null
$script:ListLoadAllButton = $null
$script:ListDiagramButton = $null
$script:DiagramState = $null
$script:DiagramForm = $null
$script:DiagramPanel = $null
$script:DiagramWordLabel = $null
$script:DiagramIndexLabel = $null
$script:DiagramPreviousButton = $null
$script:DiagramNextButton = $null
$script:DiagramJumpBox = $null
$script:ActiveContextMenu = $null

$script:StatisticsRows = @()
$script:DisplayedStatisticsDataTable = $null
$script:AvailableStatisticIds = @()
$script:UpdatingStatisticsFilters = $false
$script:StatisticsDataTable = $null
$script:CurrentStatisticsFile = ''
$script:CurrentStatisticIds = @()
$script:SelectedStatisticIds = @('descents', 'major_index', 'inversions', 'peaks')
$script:ListStatisticCombo = $null
$script:ListStatisticIds = @('')
$script:DiagramStatisticLabel = $null
$script:PendingInspection = $null
$script:PendingPatternQuery = $null
$script:InspectionSummaryRows = @()
$script:InspectionWord = ''
$script:InspectionOccurrenceRows = @()
$script:PatternQueryRows = @()

# IDs are identical to those accepted by the C++ engine.  Scalar and set-valued
# statistics can both be accumulated as exact distributions during enumeration.
$script:StatisticCatalog = @(
    [pscustomobject]@{ Id='ascents'; Label='Number of ascents'; Category='Adjacent comparisons' },
    [pscustomobject]@{ Id='descents'; Label='Number of descents'; Category='Adjacent comparisons' },
    [pscustomobject]@{ Id='weak_ascents'; Label='Number of weak ascents'; Category='Adjacent comparisons' },
    [pscustomobject]@{ Id='weak_descents'; Label='Number of weak descents'; Category='Adjacent comparisons' },
    [pscustomobject]@{ Id='equal_adjacencies'; Label='Number of equal adjacencies'; Category='Adjacent comparisons' },
    [pscustomobject]@{ Id='major_index'; Label='Major index'; Category='Mahonian statistics' },
    [pscustomobject]@{ Id='weak_major_index'; Label='Weak major index'; Category='Mahonian statistics' },
    [pscustomobject]@{ Id='inversions'; Label='Number of inversions'; Category='Mahonian statistics' },
    [pscustomobject]@{ Id='coinversions'; Label='Number of coinversions'; Category='Mahonian statistics' },
    [pscustomobject]@{ Id='peaks'; Label='Number of peaks'; Category='Peaks and valleys' },
    [pscustomobject]@{ Id='valleys'; Label='Number of valleys'; Category='Peaks and valleys' },
    [pscustomobject]@{ Id='left_peaks'; Label='Number of left peaks'; Category='Peaks and valleys' },
    [pscustomobject]@{ Id='fixed_points'; Label='Number of fixed points'; Category='Word statistics' },
    [pscustomobject]@{ Id='letter_sum'; Label='Sum of letters'; Category='Word statistics' },
    [pscustomobject]@{ Id='maximum'; Label='Number of blocks (maximum letter)'; Category='Word statistics' },
    [pscustomobject]@{ Id='strict_increasing_runs'; Label='Strictly increasing runs'; Category='Runs' },
    [pscustomobject]@{ Id='strict_decreasing_runs'; Label='Strictly decreasing runs'; Category='Runs' },
    [pscustomobject]@{ Id='weak_increasing_runs'; Label='Weakly increasing runs'; Category='Runs' },
    [pscustomobject]@{ Id='weak_decreasing_runs'; Label='Weakly decreasing runs'; Category='Runs' },
    [pscustomobject]@{ Id='singleton_letters'; Label='Number of singleton blocks'; Category='Evaluation' },
    [pscustomobject]@{ Id='repeated_letters'; Label='Number of nonsingleton blocks'; Category='Evaluation' },
    [pscustomobject]@{ Id='ascent_set'; Label='Ascent set'; Category='Set-valued statistics' },
    [pscustomobject]@{ Id='descent_set'; Label='Descent set'; Category='Set-valued statistics' },
    [pscustomobject]@{ Id='weak_ascent_set'; Label='Weak ascent set'; Category='Set-valued statistics' },
    [pscustomobject]@{ Id='weak_descent_set'; Label='Weak descent set'; Category='Set-valued statistics' },
    [pscustomobject]@{ Id='peak_set'; Label='Peak set'; Category='Set-valued statistics' },
    [pscustomobject]@{ Id='valley_set'; Label='Valley set'; Category='Set-valued statistics' },
    [pscustomobject]@{ Id='fixed_point_set'; Label='Fixed-point set'; Category='Set-valued statistics' },
    [pscustomobject]@{ Id='evaluation'; Label='Block-size evaluation'; Category='Evaluation' }
)

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Read-SharedFileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 1,
        [int]$DelayMilliseconds = 75
    )

    if ($Attempts -lt 1) { $Attempts = 1 }
    $lastException = $null
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $stream = $null
        $memory = $null
        try {
            # The native process may still have the file open for writing.  Request
            # read/write/delete sharing so a harmless live-log read does not
            # interfere with the writer.  Some Windows file-system versions still report
            # a transient sharing violation; callers can request retries.
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $stream = [System.IO.File]::Open(
                $Path,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                $share
            )
            $memory = New-Object System.IO.MemoryStream
            $stream.CopyTo($memory)
            return ,$memory.ToArray()
        }
        catch {
            $lastException = $_.Exception
            if ($attempt -lt $Attempts) {
                Start-Sleep -Milliseconds $DelayMilliseconds
            }
        }
        finally {
            if ($null -ne $memory) { $memory.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }

    if ($null -ne $lastException) { throw $lastException }
    throw "Could not read file: $Path"
}

function Read-TextFileAutoEncoding {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 1,
        [int]$DelayMilliseconds = 75
    )

    $bytes = Read-SharedFileBytes -Path $Path -Attempts $Attempts -DelayMilliseconds $DelayMilliseconds
    if ($bytes.Length -eq 0) { return '' }

    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }

    $sampleLength = [Math]::Min($bytes.Length, 4096)
    $oddNulls = 0
    $evenNulls = 0
    for ($i = 0; $i -lt $sampleLength; $i++) {
        if ($bytes[$i] -eq 0) {
            if (($i % 2) -eq 0) { $evenNulls++ } else { $oddNulls++ }
        }
    }
    $threshold = [Math]::Max(2, [int]($sampleLength / 12))
    if ($oddNulls -ge $threshold -and $oddNulls -gt (3 * $evenNulls)) {
        return [System.Text.Encoding]::Unicode.GetString($bytes)
    }
    if ($evenNulls -ge $threshold -and $evenNulls -gt (3 * $oddNulls)) {
        return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes)
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false, $false)
    return $utf8.GetString($bytes)
}

function Import-CsvWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Attempts = 40,
        [int]$DelayMilliseconds = 100
    )

    $text = Read-TextFileAutoEncoding -Path $Path -Attempts $Attempts -DelayMilliseconds $DelayMilliseconds
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $lines = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) { return @() }
    return @($lines | ConvertFrom-Csv)
}

function Get-SafeWindowsWorkingDirectory {
    foreach ($candidate in @($env:USERPROFILE, ($env:SystemDrive + '\'), $env:WINDIR)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($candidate)
            $isDrivePath = $false
            if ($full.Length -ge 3) {
                $first = [char]$full[0]
                $second = [char]$full[1]
                $third = [char]$full[2]
                $isDrivePath = ([char]::IsLetter($first) -and $second -eq [char]58 -and ($third -eq [char]92 -or $third -eq [char]47))
            }
            if ($isDrivePath -and (Test-Path -LiteralPath $full)) { return $full }
        }
        catch { }
    }
    return 'C:\'
}

function Quote-WindowsArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    # Quote according to the CommandLineToArgvW rules used by ordinary Windows
    # C/C++ programs.  This correctly preserves embedded quotation marks and
    # trailing backslashes, unlike a simple Replace('"', '\"').
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) { [void]$builder.Append(('\' * ($backslashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Convert-CsvToDataTable {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows)

    $table = New-Object System.Data.DataTable
    if ($Rows.Count -eq 0) {
        # PowerShell normally enumerates DataTable rows when a table is emitted
        # from a function.  The unary comma preserves the DataTable itself.
        return ,$table
    }
    foreach ($property in $Rows[0].PSObject.Properties) {
        [void]$table.Columns.Add($property.Name, [string])
    }
    foreach ($row in $Rows) {
        $dataRow = $table.NewRow()
        foreach ($property in $row.PSObject.Properties) {
            $dataRow[$property.Name] = [string]$property.Value
        }
        [void]$table.Rows.Add($dataRow)
    }
    return ,$table
}

function Get-CommittedNumericValue {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.NumericUpDown]$Control,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    # A typed NumericUpDown value is not guaranteed to reach .Value until the
    # edit control is validated.  Parse the displayed text as well as calling
    # ValidateChildren, then assign the parsed value back to the control.
    $text = ([string]$Control.Text).Trim()
    [decimal]$parsed = 0
    $style = [System.Globalization.NumberStyles]::Number
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    if (-not [decimal]::TryParse($text, $style, $culture, [ref]$parsed)) {
        throw "$DisplayName is not a valid integer: $text"
    }
    if ($parsed -ne [decimal]::Truncate($parsed)) {
        throw "$DisplayName must be an integer."
    }
    if ($parsed -lt $Control.Minimum -or $parsed -gt $Control.Maximum) {
        throw "$DisplayName must be between $($Control.Minimum) and $($Control.Maximum)."
    }
    $Control.Value = $parsed
    return [int]$parsed
}

function Format-GuiError {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$Record)

    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add([string]$Record.Exception.Message)
    if ($null -ne $Record.InvocationInfo -and $Record.InvocationInfo.ScriptLineNumber -gt 0) {
        $parts.Add("GUI source line: $($Record.InvocationInfo.ScriptLineNumber)")
        if (-not [string]::IsNullOrWhiteSpace($Record.InvocationInfo.Line)) {
            $parts.Add(('Statement: ' + $Record.InvocationInfo.Line.Trim()))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Record.ScriptStackTrace)) {
        $parts.Add(('Stack: ' + $Record.ScriptStackTrace))
    }
    return ($parts.ToArray() -join "`r`n")
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 22)
    $control = New-Object System.Windows.Forms.Label
    $control.Text = $Text
    $control.Location = New-Object System.Drawing.Point($X, $Y)
    $control.Size = New-Object System.Drawing.Size($Width, $Height)
    return $control
}

function New-NumericBox {
    param([int]$X, [int]$Y, [int]$Width, [decimal]$Minimum, [decimal]$Maximum, [decimal]$Value)
    $control = New-Object System.Windows.Forms.NumericUpDown
    $control.Location = New-Object System.Drawing.Point($X, $Y)
    $control.Size = New-Object System.Drawing.Size($Width, 24)
    $control.Minimum = $Minimum
    $control.Maximum = $Maximum
    $control.Value = $Value
    $control.TextAlign = [System.Windows.Forms.HorizontalAlignment]::Right
    return $control
}

function Append-LogText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $logBox.Text = $Text
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Get-ClassDisplayNames {
    param([Parameter(Mandatory = $true)][string]$Text)

    # Use a native PowerShell array here. Windows PowerShell 5.1 can throw
    # "Argument types do not match" when @() is applied directly to a
    # System.Collections.Generic.List[object]. The number of classes is small,
    # so an ordinary array is both reliable and entirely adequate.
    $result = @()
    $index = 1
    foreach ($rawLine in ($Text -split "`r?`n")) {
        $line = [string]$rawLine
        $hash = $line.IndexOf('#')
        if ($hash -ge 0) { $line = $line.Substring(0, $hash) }
        $line = $line.Trim()
        if ($line.Length -eq 0) { continue }
        $equals = $line.IndexOf('=')
        if ($equals -ge 0) {
            $name = $line.Substring(0, $equals).Trim()
            $basis = $line.Substring($equals + 1).Trim()
        }
        else {
            $basis = $line
            $name = "Av($basis)"
        }
        if ([string]::IsNullOrWhiteSpace($name)) { $name = "Class $index" }
        $result += [pscustomobject]@{ Index = $index; Name = $name; Basis = $basis }
        $index++
    }
    return $result
}

function Update-ClassInfo {
    $script:CurrentClasses = @()
    if ($null -eq $script:TotalsDataTable) { return }

    $known = @(
        'n', 'k', 'cayley_words', 'rgf_words', 'difference_1_minus_2', 'seconds',
        'engine', 'search_nodes', 'surviving_leaves', 'prefix_tasks', 'split_depth'
    )
    $columns = @()
    foreach ($column in $script:TotalsDataTable.Columns) {
        if ($known -notcontains [string]$column.ColumnName) { $columns += [string]$column.ColumnName }
    }
    $names = @(Get-ClassDisplayNames -Text $script:CurrentClassText)
    $items = @()
    for ($i = 0; $i -lt $columns.Count; $i++) {
        $display = if ($i -lt $names.Count) { $names[$i].Name } else { $columns[$i] }
        $basis = if ($i -lt $names.Count) { $names[$i].Basis } else { '' }
        $items += [pscustomobject]@{
            Index = $i + 1
            Name = [string]$display
            Basis = [string]$basis
            Column = [string]$columns[$i]
        }
    }
    $script:CurrentClasses = $items
}



# ---------------------------- OEIS lookup ----------------------------------
# OEIS checks use only the finitely many totals currently displayed.  A match
# is therefore evidence, not a proof that two infinite sequences are equal.

function Normalize-OeisIntegerString {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return $null }
    $text = $Value.Trim()
    if ($text -notmatch '^[+-]?\d+$') { return $null }
    $negative = $text.StartsWith('-')
    $digits = ($text -replace '^[+-]', '')
    $digits = ($digits -replace '^0+(?=\d)', '')
    if ([string]::IsNullOrWhiteSpace($digits)) { $digits = '0' }
    if ($negative -and $digits -ne '0') { return '-' + $digits }
    return $digits
}

function Get-OeisDataTerms {
    param([AllowNull()][string]$Data)

    $terms = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Data)) { return @() }
    foreach ($piece in ($Data -split ',')) {
        $term = Normalize-OeisIntegerString -Value $piece
        if ($null -eq $term) { return @() }
        $terms.Add($term)
    }
    return $terms.ToArray()
}

function Test-OeisTermSlice {
    param(
        [Parameter(Mandatory = $true)][object[]]$Candidate,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][object[]]$Query
    )

    if ($Start -lt 0 -or $Start + $Query.Count -gt $Candidate.Count) { return $false }
    for ($i = 0; $i -lt $Query.Count; $i++) {
        if ([string]$Candidate[$Start + $i] -ne [string]$Query[$i]) { return $false }
    }
    return $true
}

function Find-OeisTermSlice {
    param(
        [Parameter(Mandatory = $true)][object[]]$Candidate,
        [Parameter(Mandatory = $true)][object[]]$Query
    )

    if ($Query.Count -eq 0 -or $Query.Count -gt $Candidate.Count) { return -1 }
    for ($start = 0; $start -le $Candidate.Count - $Query.Count; $start++) {
        if (Test-OeisTermSlice -Candidate $Candidate -Start $start -Query $Query) { return $start }
    }
    return -1
}

function New-OeisLookupRequest {
    param([Parameter(Mandatory = $true)]$Class)

    $entries = @()
    foreach ($row in $script:TotalsDataTable.Rows) {
        [int]$nValue = 0
        if (-not [int]::TryParse(([string]$row['n']).Trim(), [ref]$nValue)) { continue }
        $term = Normalize-OeisIntegerString -Value ([string]$row[$Class.Column])
        if ($null -eq $term) { continue }
        $entries += [pscustomobject]@{ N = $nValue; Term = $term }
    }
    $entries = @($entries | Sort-Object N)

    if ($entries.Count -eq 0) {
        return [pscustomobject]@{
            Ready = $false; Column = [string]$Class.Column; ClassName = [string]$Class.Name
            Reason = 'No integer terms are available.'; Terms = @(); QueryText = ''; SearchUrl = ''
        }
    }

    # Very short searches generate many accidental matches.  Six terms is the
    # minimum automatic lookup and usually provides substantially better
    # evidence.  Following the OEIS search guidance, use about six to ten
    # consecutive terms, prefer the latest terms, and omit generic leading 0's
    # or 1's when enough terms remain.
    if ($entries.Count -lt 6) {
        return [pscustomobject]@{
            Ready = $false; Column = [string]$Class.Column; ClassName = [string]$Class.Name
            Reason = "Too few terms for an automatic OEIS check ($($entries.Count) available; at least 6 required)."
            Terms = @($entries | ForEach-Object { [string]$_.Term }); QueryText = ''; SearchUrl = ''
        }
    }

    $window = @($entries | Select-Object -Last 10)
    while ($window.Count -gt 6 -and ([string]$window[0].Term -eq '0' -or [string]$window[0].Term -eq '1')) {
        $window = @($window | Select-Object -Skip 1)
    }
    $queryText = (@($window | ForEach-Object { [string]$_.Term }) -join ',')
    while ($queryText.Length -gt 1400 -and $window.Count -gt 6) {
        $window = @($window | Select-Object -Skip 1)
        $queryText = (@($window | ForEach-Object { [string]$_.Term }) -join ',')
    }

    $firstN = [int]$window[0].N
    $lastN = [int]$window[$window.Count - 1].N
    $encoded = [System.Uri]::EscapeDataString($queryText)
    return [pscustomobject]@{
        Ready = $true
        Column = [string]$Class.Column
        ClassName = [string]$Class.Name
        FirstN = $firstN
        LastN = $lastN
        Terms = @($window | ForEach-Object { [string]$_.Term })
        QueryText = $queryText
        CacheKey = ("{0}|{1}|{2}" -f ([string]$Class.Column), $firstN, $queryText)
        ApiUrl = ('https://oeis.org/search?fmt=json&q=' + $encoded)
        SearchUrl = ('https://oeis.org/search?q=' + $encoded)
    }
}

function Reset-OeisLookups {
    $script:OeisLookupGeneration++
    if ($null -ne $script:OeisLookupTimer) { $script:OeisLookupTimer.Stop() }
    if ($null -ne $script:OeisLookupQueue) { $script:OeisLookupQueue.Clear() }
    $script:OeisActiveLookup = $null
    $script:OeisResultsByColumn = @{}
}

function Find-OeisFooterGridRow {
    if ($null -eq $totalsGrid -or $null -eq $totalsGrid.Columns['n']) { return $null }
    $nIndex = $totalsGrid.Columns['n'].Index
    foreach ($row in $totalsGrid.Rows) {
        if ([string]$row.Cells[$nIndex].Value -eq 'OEIS*') { return $row }
    }
    return $null
}

function Style-OeisFooterRow {
    $row = Find-OeisFooterGridRow
    if ($null -eq $row) { return }

    $row.Height = 42
    $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 250, 230)
    $row.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(245, 235, 190)
    $row.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True
    $row.DefaultCellStyle.Font = New-Object System.Drawing.Font($totalsGrid.Font, [System.Drawing.FontStyle]::Bold)
    $row.Cells[$totalsGrid.Columns['n'].Index].ToolTipText = 'Automatic finite-sequence lookup in the OEIS. A match is evidence only, not proof of equality of infinite sequences.'

    foreach ($column in $totalsGrid.Columns) {
        $column.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::NotSortable
    }
    foreach ($class in $script:CurrentClasses) {
        if ($null -eq $totalsGrid.Columns[$class.Column]) { continue }
        $cell = $row.Cells[$totalsGrid.Columns[$class.Column].Index]
        $cell.Style.ForeColor = [System.Drawing.Color]::SteelBlue
        $cell.Style.SelectionForeColor = [System.Drawing.Color]::SteelBlue
    }
}

function Set-OeisFooterCell {
    param(
        [Parameter(Mandatory = $true)][string]$Column,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ToolTip,
        [Parameter(Mandatory = $true)][System.Drawing.Color]$Color,
        [AllowNull()]$Result
    )

    if ($null -ne $script:OeisFooterRow -and $script:OeisFooterRow.Table.Columns.Contains($Column)) {
        $script:OeisFooterRow[$Column] = $Text
    }
    if ($null -ne $Result) { $script:OeisResultsByColumn[$Column] = $Result }

    $gridRow = Find-OeisFooterGridRow
    if ($null -ne $gridRow -and $null -ne $totalsGrid.Columns[$Column]) {
        $cell = $gridRow.Cells[$totalsGrid.Columns[$Column].Index]
        $cell.ToolTipText = $ToolTip
        $cell.Style.ForeColor = $Color
        $cell.Style.SelectionForeColor = $Color
    }
    $totalsGrid.Refresh()
}

function Initialize-OeisFooter {
    Reset-OeisLookups
    $script:TotalsDisplayDataTable = $script:TotalsDataTable.Copy()
    $footer = $script:TotalsDisplayDataTable.NewRow()
    foreach ($column in $script:TotalsDisplayDataTable.Columns) { $footer[$column.ColumnName] = '' }
    if ($script:TotalsDisplayDataTable.Columns.Contains('n')) { $footer['n'] = 'OEIS*' }
    if ($script:TotalsDisplayDataTable.Columns.Contains('cayley_words')) { $footer['cayley_words'] = 'finite-sequence check' }
    if ($script:TotalsDisplayDataTable.Columns.Contains('rgf_words')) { $footer['rgf_words'] = 'finite-sequence check' }
    foreach ($class in $script:CurrentClasses) {
        if ($script:TotalsDisplayDataTable.Columns.Contains($class.Column)) { $footer[$class.Column] = 'Pending…' }
    }
    [void]$script:TotalsDisplayDataTable.Rows.Add($footer)
    $script:OeisFooterRow = $footer
}

function ConvertFrom-OeisResponse {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'The OEIS returned an empty response.' }
    $response = $Json | ConvertFrom-Json
    $rawResults = @()
    [int]$reportedCount = 0

    if ($response -is [System.Array]) {
        $rawResults = @($response)
        $reportedCount = $rawResults.Count
    }
    elseif ($null -ne $response -and $null -ne $response.PSObject.Properties['results']) {
        $rawResults = @($response.results)
        if ($null -ne $response.PSObject.Properties['count']) {
            [void][int]::TryParse([string]$response.count, [ref]$reportedCount)
        }
    }
    elseif ($null -ne $response -and $null -ne $response.PSObject.Properties['number']) {
        $rawResults = @($response)
        $reportedCount = 1
    }

    $queryTerms = @($Request.Terms)
    $matches = @()
    foreach ($candidate in $rawResults) {
        if ($null -eq $candidate -or $null -eq $candidate.PSObject.Properties['number'] -or
            $null -eq $candidate.PSObject.Properties['data']) { continue }

        [int]$number = 0
        if (-not [int]::TryParse([string]$candidate.number, [ref]$number)) { continue }
        $candidateTerms = @(Get-OeisDataTerms -Data ([string]$candidate.data))
        if ($candidateTerms.Count -lt $queryTerms.Count) { continue }

        [int]$offset = 0
        $offsetText = if ($null -ne $candidate.PSObject.Properties['offset']) { [string]$candidate.offset } else { '0' }
        $offsetFirst = ($offsetText -split ',')[0].Trim()
        [void][int]::TryParse($offsetFirst, [ref]$offset)

        $alignedStart = [int]$Request.FirstN - $offset
        $kind = ''
        $matchStart = -1
        if (Test-OeisTermSlice -Candidate $candidateTerms -Start $alignedStart -Query $queryTerms) {
            $kind = 'indexed'
            $matchStart = $alignedStart
        }
        else {
            $matchStart = Find-OeisTermSlice -Candidate $candidateTerms -Query $queryTerms
            if ($matchStart -ge 0) { $kind = 'value' }
        }
        if ([string]::IsNullOrWhiteSpace($kind)) { continue }

        $id = ('A{0:000000}' -f $number)
        $name = if ($null -ne $candidate.PSObject.Properties['name']) { [string]$candidate.name } else { '' }
        $keywords = if ($null -ne $candidate.PSObject.Properties['keyword']) { [string]$candidate.keyword } else { '' }
        $matches += [pscustomobject]@{
            Id = $id; Name = $name; Kind = $kind; Offset = $offset; MatchStart = $matchStart
            Keywords = $keywords; Url = ('https://oeis.org/' + $id)
        }
    }

    # Keep every collection explicitly array-valued.  Windows PowerShell 5.1
    # unwraps the output of an if statement when it contains exactly one
    # object.  Under StrictMode, asking that scalar object for .Count raises
    # "The property 'Count' cannot be found".  This occurred precisely for
    # otherwise successful OEIS searches having one matching entry.
    [object[]]$indexed = @($matches | Where-Object { $_.Kind -eq 'indexed' })
    [object[]]$valueOnly = @($matches | Where-Object { $_.Kind -eq 'value' })
    [object[]]$preferred = @()
    $kindLabel = 'none'
    if ($indexed.Length -gt 0) {
        $preferred = @($indexed)
        $kindLabel = 'indexed'
    }
    elseif ($valueOnly.Length -gt 0) {
        $preferred = @($valueOnly)
        $kindLabel = 'value'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Finite-sequence OEIS check for $($Request.ClassName)")
    $lines.Add("Terms used: $($Request.Terms.Count), indexed by n=$($Request.FirstN)..$($Request.LastN)")
    $lines.Add('Finite agreement does not prove that the infinite sequences are identical.')
    $lines.Add('')

    if ($preferred.Length -eq 0) {
        $lines.Add('No matching finite sequence was found among the OEIS search results returned for these terms.')
        return [pscustomobject]@{
            Status = 'none'; DisplayText = 'No OEIS match found'; ToolTip = ($lines.ToArray() -join "`r`n")
            PrimaryUrl = ''; SearchUrl = [string]$Request.SearchUrl; QueryText = [string]$Request.QueryText
            Matches = @(); ReportedCount = $reportedCount
        }
    }

    if ($kindLabel -eq 'indexed') {
        $lines.Add('OEIS entries whose offsets align with the displayed n-values:')
    }
    else {
        $lines.Add('OEIS entries containing the same finite value list, but with a different displayed offset:')
    }
    foreach ($match in @($preferred | Select-Object -First 10)) {
        $suffix = if ([string]::IsNullOrWhiteSpace($match.Name)) { '' } else { ': ' + $match.Name }
        $lines.Add("$($match.Id)$suffix")
    }
    if ($preferred.Length -gt 10) { $lines.Add("...and $($preferred.Length - 10) more returned matches.") }

    $display = if ($preferred.Length -eq 1) {
        if ($kindLabel -eq 'indexed') { "$($preferred[0].Id) (indexed match)" }
        else { "$($preferred[0].Id) (value-list match)" }
    }
    elseif ($kindLabel -eq 'indexed') { "$($preferred.Length) indexed matches" }
    else { "$($preferred.Length) possible value-list matches" }

    return [pscustomobject]@{
        Status = $kindLabel; DisplayText = $display; ToolTip = ($lines.ToArray() -join "`r`n")
        PrimaryUrl = [string]$preferred[0].Url; SearchUrl = [string]$Request.SearchUrl
        QueryText = [string]$Request.QueryText; Matches = @($preferred); ReportedCount = $reportedCount
    }
}

function Apply-OeisLookupResult {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)]$Result
    )

    $color = switch ([string]$Result.Status) {
        'indexed' { [System.Drawing.Color]::DarkGreen }
        'value'   { [System.Drawing.Color]::DarkGoldenrod }
        'none'    { [System.Drawing.Color]::DimGray }
        'short'   { [System.Drawing.Color]::DimGray }
        default   { [System.Drawing.Color]::Firebrick }
    }
    Set-OeisFooterCell -Column ([string]$Request.Column) -Text ([string]$Result.DisplayText) `
        -ToolTip ([string]$Result.ToolTip) -Color $color -Result $Result
}

function New-OeisErrorResult {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][string]$Message
    )
    return [pscustomobject]@{
        Status = 'error'; DisplayText = 'OEIS lookup unavailable'
        ToolTip = "The online OEIS check could not be completed.`r`n`r`n$Message`r`n`r`nDouble-click this cell to open the OEIS search in a web browser."
        PrimaryUrl = ''; SearchUrl = [string]$Request.SearchUrl; QueryText = [string]$Request.QueryText; Matches = @()
    }
}

function Start-NextOeisLookup {
    if ($null -ne $script:OeisActiveLookup) { return }
    if ($null -eq $script:OeisLookupQueue -or $script:OeisLookupQueue.Count -eq 0) {
        if ($null -ne $script:OeisLookupTimer) { $script:OeisLookupTimer.Stop() }
        return
    }

    $request = $script:OeisLookupQueue.Dequeue()
    if ($null -eq $script:OeisHttpClient) {
        $result = New-OeisErrorResult -Request $request -Message 'The Windows HTTP client could not be initialized.'
        Apply-OeisLookupResult -Request $request -Result $result
        Start-NextOeisLookup
        return
    }

    Set-OeisFooterCell -Column ([string]$request.Column) -Text 'Checking OEIS…' `
        -ToolTip 'The online finite-sequence lookup is running in the background.' `
        -Color ([System.Drawing.Color]::SteelBlue) -Result $null
    try {
        $task = $script:OeisHttpClient.GetStringAsync([string]$request.ApiUrl)
        $script:OeisActiveLookup = [pscustomobject]@{
            Request = $request; Task = $task; Generation = $script:OeisLookupGeneration
        }
        $script:OeisLookupTimer.Start()
    }
    catch {
        $result = New-OeisErrorResult -Request $request -Message $_.Exception.Message
        Apply-OeisLookupResult -Request $request -Result $result
        Start-NextOeisLookup
    }
}

function Complete-OeisLookupTick {
    if ($null -eq $script:OeisActiveLookup) {
        Start-NextOeisLookup
        return
    }
    $active = $script:OeisActiveLookup
    if (-not $active.Task.IsCompleted) { return }
    $script:OeisActiveLookup = $null

    if ([int]$active.Generation -ne [int]$script:OeisLookupGeneration) {
        Start-NextOeisLookup
        return
    }

    $request = $active.Request
    try {
        if ($active.Task.IsCanceled) { throw 'The OEIS lookup was cancelled.' }
        if ($active.Task.IsFaulted) {
            $base = $active.Task.Exception.GetBaseException()
            throw $base.Message
        }
        $json = [string]$active.Task.Result
        $result = ConvertFrom-OeisResponse -Request $request -Json $json
        $script:OeisCache[[string]$request.CacheKey] = $result
        Apply-OeisLookupResult -Request $request -Result $result
    }
    catch {
        $result = New-OeisErrorResult -Request $request -Message $_.Exception.Message
        Apply-OeisLookupResult -Request $request -Result $result
    }
    Start-NextOeisLookup
}

function Start-OeisLookups {
    Reset-OeisLookups
    if ($null -eq $script:TotalsDataTable -or $script:CurrentClasses.Count -eq 0) { return }

    foreach ($class in $script:CurrentClasses) {
        $request = New-OeisLookupRequest -Class $class
        if (-not $request.Ready) {
            $result = [pscustomobject]@{
                Status = 'short'; DisplayText = 'Too few terms for lookup'
                ToolTip = [string]$request.Reason; PrimaryUrl = ''; SearchUrl = [string]$request.SearchUrl
                QueryText = [string]$request.QueryText; Matches = @()
            }
            Apply-OeisLookupResult -Request $request -Result $result
            continue
        }
        if ($script:OeisCache.ContainsKey([string]$request.CacheKey)) {
            Apply-OeisLookupResult -Request $request -Result $script:OeisCache[[string]$request.CacheKey]
            continue
        }
        $script:OeisLookupQueue.Enqueue($request)
    }
    Start-NextOeisLookup
}

function Open-OeisUrl {
    param([AllowNull()][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return }
    try { Start-Process -FilePath $Url | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Open OEIS error') | Out-Null }
}

function Test-IsOeisFooterRow {
    param([Parameter(Mandatory = $true)]$Grid, [Parameter(Mandatory = $true)][int]$RowIndex)
    if ($RowIndex -lt 0 -or $null -eq $Grid.Columns['n']) { return $false }
    return ([string]$Grid.Rows[$RowIndex].Cells[$Grid.Columns['n'].Index].Value -eq 'OEIS*')
}

function Show-OeisContextMenu {
    param(
        [Parameter(Mandatory = $true)]$Grid,
        [Parameter(Mandatory = $true)][int]$ColumnIndex,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y
    )

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $columnName = if ($ColumnIndex -ge 0) { [string]$Grid.Columns[$ColumnIndex].Name } else { '' }
    $result = if (-not [string]::IsNullOrWhiteSpace($columnName) -and $script:OeisResultsByColumn.ContainsKey($columnName)) {
        $script:OeisResultsByColumn[$columnName]
    } else { $null }

    $openPrimary = New-Object System.Windows.Forms.ToolStripMenuItem
    $openPrimary.Text = 'Open primary OEIS match'
    $openPrimary.Enabled = ($null -ne $result -and -not [string]::IsNullOrWhiteSpace([string]$result.PrimaryUrl))
    if ($openPrimary.Enabled) {
        $openPrimary.Tag = [string]$result.PrimaryUrl
        $openPrimary.Add_Click({ param($sender, $eventArgs) Open-OeisUrl -Url ([string]$sender.Tag) })
    }
    [void]$menu.Items.Add($openPrimary)

    $openSearch = New-Object System.Windows.Forms.ToolStripMenuItem
    $openSearch.Text = 'Open OEIS search for these terms'
    $openSearch.Enabled = ($null -ne $result -and -not [string]::IsNullOrWhiteSpace([string]$result.SearchUrl))
    if ($openSearch.Enabled) {
        $openSearch.Tag = [string]$result.SearchUrl
        $openSearch.Add_Click({ param($sender, $eventArgs) Open-OeisUrl -Url ([string]$sender.Tag) })
    }
    [void]$menu.Items.Add($openSearch)

    $copyTerms = New-Object System.Windows.Forms.ToolStripMenuItem
    $copyTerms.Text = 'Copy queried terms'
    $copyTerms.Enabled = ($null -ne $result -and -not [string]::IsNullOrWhiteSpace([string]$result.QueryText))
    if ($copyTerms.Enabled) {
        $copyTerms.Tag = [string]$result.QueryText
        $copyTerms.Add_Click({ param($sender, $eventArgs) [System.Windows.Forms.Clipboard]::SetText([string]$sender.Tag) })
    }
    [void]$menu.Items.Add($copyTerms)

    $separator = New-Object System.Windows.Forms.ToolStripSeparator
    [void]$menu.Items.Add($separator)
    $refresh = New-Object System.Windows.Forms.ToolStripMenuItem
    $refresh.Text = 'Refresh all OEIS checks'
    $refresh.Add_Click({
        $script:OeisCache.Clear()
        Start-OeisLookups
    })
    [void]$menu.Items.Add($refresh)

    $script:ActiveContextMenu = $menu
    $menu.Show($Grid, (New-Object System.Drawing.Point($X, $Y)))
}

function Get-StatisticItemById {
    param([Parameter(Mandatory = $true)][string]$Id)
    foreach ($item in $script:StatisticCatalog) {
        if ([string]$item.Id -eq $Id) { return $item }
    }
    return $null
}

function Get-StatisticLabel {
    param([Parameter(Mandatory = $true)][string]$Id)
    $item = Get-StatisticItemById -Id $Id
    if ($null -eq $item) { return $Id }
    return [string]$item.Label
}

function Update-StatisticSelectionSummary {
    if ($null -eq $statisticsSelectionLabel) { return }
    if ($script:SelectedStatisticIds.Count -eq 0) {
        $statisticsSelectionLabel.Text = 'No statistics selected.'
        return
    }
    $labels = @()
    foreach ($id in $script:SelectedStatisticIds) { $labels += (Get-StatisticLabel -Id ([string]$id)) }
    if ($labels.Count -le 3) {
        $statisticsSelectionLabel.Text = ($labels -join ', ')
    }
    else {
        $statisticsSelectionLabel.Text = ('{0}, {1}, {2}, and {3} more' -f $labels[0], $labels[1], $labels[2], ($labels.Count - 3))
    }
}

function Show-StatisticSelectionDialog {
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Select statistic distributions'
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Size = New-Object System.Drawing.Size(610, 650)
    $dialog.MinimumSize = New-Object System.Drawing.Size(520, 520)
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $intro = New-Label -Text 'Selected distributions are accumulated while avoiding RGFs are generated; the RGFs themselves need not be stored.' -X 14 -Y 12 -Width 565 -Height 38
    $dialog.Controls.Add($intro)

    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Location = New-Object System.Drawing.Point(15, 55)
    $list.Size = New-Object System.Drawing.Size(560, 490)
    $list.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $list.CheckOnClick = $true
    $list.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $lastCategory = ''
    foreach ($item in $script:StatisticCatalog) {
        $text = '{0} - {1}' -f $item.Category, $item.Label
        $index = $list.Items.Add($text)
        if ($script:SelectedStatisticIds -contains [string]$item.Id) { $list.SetItemChecked($index, $true) }
    }
    $dialog.Controls.Add($list)

    $selectAll = New-Object System.Windows.Forms.Button
    $selectAll.Text = 'Select all'
    $selectAll.Location = New-Object System.Drawing.Point(15, 558)
    $selectAll.Size = New-Object System.Drawing.Size(90, 30)
    $selectAll.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $dialog.Controls.Add($selectAll)
    $clear = New-Object System.Windows.Forms.Button
    $clear.Text = 'Clear'
    $clear.Location = New-Object System.Drawing.Point(112, 558)
    $clear.Size = New-Object System.Drawing.Size(80, 30)
    $clear.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $dialog.Controls.Add($clear)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Use selected'
    $ok.Location = New-Object System.Drawing.Point(372, 558)
    $ok.Size = New-Object System.Drawing.Size(105, 30)
    $ok.Anchor = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'
    $cancel.Location = New-Object System.Drawing.Point(484, 558)
    $cancel.Size = New-Object System.Drawing.Size(90, 30)
    $cancel.Anchor = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel

    $selectAll.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $true) } })
    $clear.Add_Click({ for ($i = 0; $i -lt $list.Items.Count; $i++) { $list.SetItemChecked($i, $false) } })

    if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $chosen = @()
        for ($i = 0; $i -lt $script:StatisticCatalog.Count; $i++) {
            if ($list.GetItemChecked($i)) { $chosen += [string]$script:StatisticCatalog[$i].Id }
        }
        $script:SelectedStatisticIds = $chosen
        if ($chosen.Count -gt 0) { $collectStatisticsCheck.Checked = $true }
        Update-StatisticSelectionSummary
    }
    $dialog.Dispose()
}

function Clear-StatisticsDisplay {
    $script:StatisticsDataTable = $null
    $script:DisplayedStatisticsDataTable = $null
    $script:AvailableStatisticIds = @()
    if ($null -ne $statisticsGrid) { $statisticsGrid.DataSource = $null }
    foreach ($combo in @($statisticsClassCombo, $statisticsStatisticCombo, $statisticsNCombo, $statisticsScopeCombo)) {
        if ($null -ne $combo) { $combo.Items.Clear(); $combo.Enabled = $false }
    }
    if ($null -ne $statisticsTotalLabel) { $statisticsTotalLabel.Text = 'No statistic distributions have been collected.' }
    if ($null -ne $statisticsExportButton) { $statisticsExportButton.Enabled = $false }
}

function Update-StatisticsScopeChoices {
    if ($script:UpdatingStatisticsFilters) { return }
    if ($script:StatisticsRows.Count -eq 0 -or $statisticsNCombo.SelectedIndex -lt 0 -or
        $statisticsClassCombo.SelectedIndex -lt 0 -or $statisticsStatisticCombo.SelectedIndex -lt 0) { return }
    $script:UpdatingStatisticsFilters = $true
    try {
        $className = [string]$statisticsClassCombo.SelectedItem
        $statisticId = [string]$script:AvailableStatisticIds[$statisticsStatisticCombo.SelectedIndex]
        $nText = [string]$statisticsNCombo.SelectedItem
        $previous = if ($statisticsScopeCombo.SelectedIndex -ge 0) { [string]$statisticsScopeCombo.SelectedItem } else { 'All block counts' }
        $statisticsScopeCombo.Items.Clear()
        [void]$statisticsScopeCombo.Items.Add('All block counts')
        $ks = @()
        foreach ($row in $script:StatisticsRows) {
            if ([string]$row.class_name -eq $className -and [string]$row.statistic -eq $statisticId -and
                [string]$row.n -eq $nText -and [string]$row.scope -eq 'exact') {
                $value = [int]$row.k
                if ($value -gt 0 -and $ks -notcontains $value) { $ks += $value }
            }
        }
        foreach ($k in @($ks | Sort-Object)) { [void]$statisticsScopeCombo.Items.Add("blocks k = $k") }
        $found = $statisticsScopeCombo.Items.IndexOf($previous)
        $statisticsScopeCombo.SelectedIndex = if ($found -ge 0) { $found } else { 0 }
        $statisticsScopeCombo.Enabled = $true
    }
    finally { $script:UpdatingStatisticsFilters = $false }
    Refresh-StatisticsGrid
}

function Refresh-StatisticsGrid {
    if ($script:UpdatingStatisticsFilters) { return }
    if ($script:StatisticsRows.Count -eq 0 -or $statisticsClassCombo.SelectedIndex -lt 0 -or
        $statisticsStatisticCombo.SelectedIndex -lt 0 -or $statisticsNCombo.SelectedIndex -lt 0 -or
        $statisticsScopeCombo.SelectedIndex -lt 0) {
        $statisticsGrid.DataSource = $null
        return
    }
    $className = [string]$statisticsClassCombo.SelectedItem
    $statisticId = [string]$script:AvailableStatisticIds[$statisticsStatisticCombo.SelectedIndex]
    $nText = [string]$statisticsNCombo.SelectedItem
    $scopeText = [string]$statisticsScopeCombo.SelectedItem
    $scope = if ($scopeText -eq 'All block counts') { 'total' } else { 'exact' }
    $kText = if ($scope -eq 'total') { '0' } else { ($scopeText -replace '^blocks k =\s*', '') }
    $filtered = @()
    foreach ($row in $script:StatisticsRows) {
        if ([string]$row.class_name -eq $className -and [string]$row.statistic -eq $statisticId -and
            [string]$row.n -eq $nText -and [string]$row.scope -eq $scope -and [string]$row.k -eq $kText) {
            $filtered += [pscustomobject]@{ Value = [string]$row.value; Count = [string]$row.count; Order = [string]$row.value_order }
        }
    }
    $filtered = @($filtered | Sort-Object -Property 'Order', 'Value')
    $displayRows = @()
    [System.Numerics.BigInteger]$total = 0
    foreach ($row in $filtered) {
        $displayRows += [pscustomobject]@{ Value = $row.Value; Count = $row.Count }
        [System.Numerics.BigInteger]$value = 0
        if ([System.Numerics.BigInteger]::TryParse([string]$row.Count, [ref]$value)) { $total += $value }
    }
    $script:DisplayedStatisticsDataTable = Convert-CsvToDataTable -Rows $displayRows
    $statisticsGrid.DataSource = $null
    $statisticsGrid.AutoGenerateColumns = $true
    $statisticsGrid.DataSource = $script:DisplayedStatisticsDataTable.DefaultView
    $statisticsGrid.AutoResizeColumns([System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells)
    $statisticsTotalLabel.Text = ('{0}; {1}; n={2}; {3}. Total objects: {4}' -f $className, (Get-StatisticLabel -Id $statisticId), $nText, $scopeText, $total)
    $statisticsExportButton.Enabled = ($displayRows.Count -gt 0)
}

function Update-StatisticsSelectors {
    Clear-StatisticsDisplay
    if ($script:StatisticsRows.Count -eq 0) { return }
    $script:UpdatingStatisticsFilters = $true
    try {
        $classNames = @()
        $statIds = @()
        $nValues = @()
        foreach ($row in $script:StatisticsRows) {
            $className = [string]$row.class_name
            $statId = [string]$row.statistic
            $nValue = [int]$row.n
            if ($classNames -notcontains $className) { $classNames += $className }
            if ($statIds -notcontains $statId) { $statIds += $statId }
            if ($nValues -notcontains $nValue) { $nValues += $nValue }
        }
        $script:AvailableStatisticIds = $statIds
        foreach ($name in $classNames) { [void]$statisticsClassCombo.Items.Add($name) }
        foreach ($id in $statIds) { [void]$statisticsStatisticCombo.Items.Add((Get-StatisticLabel -Id $id)) }
        foreach ($n in @($nValues | Sort-Object)) { [void]$statisticsNCombo.Items.Add([string]$n) }
        foreach ($combo in @($statisticsClassCombo, $statisticsStatisticCombo, $statisticsNCombo)) {
            $combo.Enabled = $true
        }
        if ($statisticsClassCombo.Items.Count -gt 0) { $statisticsClassCombo.SelectedIndex = 0 }
        if ($statisticsStatisticCombo.Items.Count -gt 0) { $statisticsStatisticCombo.SelectedIndex = 0 }
        if ($statisticsNCombo.Items.Count -gt 0) { $statisticsNCombo.SelectedIndex = $statisticsNCombo.Items.Count - 1 }
    }
    finally { $script:UpdatingStatisticsFilters = $false }
    Update-StatisticsScopeChoices
}

function Export-CurrentStatisticDistribution {
    if ($null -eq $script:DisplayedStatisticsDataTable -or $script:DisplayedStatisticsDataTable.Rows.Count -eq 0) { return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FileName = 'rgf_statistic_distribution.csv'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $objects = @()
        foreach ($row in $script:DisplayedStatisticsDataTable.Rows) {
            $objects += [pscustomobject]@{ value = [string]$row['Value']; count = [string]$row['Count'] }
        }
        $csv = ($objects | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
        Write-Utf8NoBom -Path $dialog.FileName -Text ($csv + "`r`n")
        $statusLabel.Text = "Exported $($dialog.FileName)"
    }
    $dialog.Dispose()
}

function Set-RunningState {
    param([bool]$Running, [string]$Message)

    $installButton.Enabled = -not $Running
    $selfTestButton.Enabled = -not $Running
    $runButton.Enabled = -not $Running
    $cancelButton.Enabled = $Running
    $loadClassesButton.Enabled = -not $Running
    $saveClassesButton.Enabled = -not $Running
    $classesBox.Enabled = -not $Running
    $minNBox.Enabled = -not $Running
    $maxNBox.Enabled = -not $Running
    $threadsBox.Enabled = -not $Running
    $engineCombo.Enabled = -not $Running
    $onlyKBox.Enabled = -not $Running
    $storeAllCheck.Enabled = -not $Running
    $collectStatisticsCheck.Enabled = -not $Running
    $selectStatisticsButton.Enabled = -not $Running
    $patternSyntaxButton.Enabled = -not $Running
    $inspectButton.Enabled = -not $Running
    $patternQueryButton.Enabled = (-not $Running -and $null -ne $script:TotalsDataTable)
    $distroCombo.Enabled = $false
    $exportButton.Enabled = (-not $Running -and $null -ne $script:TotalsDataTable)
    $statusLabel.Text = $Message
}

function Close-BrowserWindows {
    if ($null -ne $script:DiagramForm -and -not $script:DiagramForm.IsDisposed) {
        try { $script:DiagramForm.Close() } catch { }
    }
    if ($null -ne $script:ListForm -and -not $script:ListForm.IsDisposed) {
        try { $script:ListForm.Close() } catch { }
    }
    $script:DiagramForm = $null
    $script:DiagramState = $null
    $script:ListForm = $null
    $script:ListState = $null
}

function Clear-CurrentRun {
    Close-BrowserWindows
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentRunDirectory) -and
        (Test-Path -LiteralPath $script:CurrentRunDirectory)) {
        Remove-Item -LiteralPath $script:CurrentRunDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:CurrentRunDirectory = ''
    $script:CurrentOutputPrefix = ''
    $script:CurrentClassFile = ''
    $script:CurrentCatalogDirectory = ''
    $script:CurrentStatisticsFile = ''
    $script:CurrentStatisticIds = @()
    $script:CurrentStoreAll = $false
    Reset-OeisLookups
    $script:TotalsDataTable = $null
    $script:TotalsDisplayDataTable = $null
    $script:OeisFooterRow = $null
    $script:ByMaxDataTable = $null
    $script:StatisticsRows = @()
    $script:CurrentClasses = @()
    $totalsGrid.DataSource = $null
    $byMaxGrid.DataSource = $null
    Clear-StatisticsDisplay
    $script:PatternQueryRows = @()
    $patternQueryGrid.DataSource = $null
    $patternQuerySummaryLabel.Text = 'Run an enumeration, then choose a class and query pattern.'
    $inspectionGrid.DataSource = $null
    $inspectionSummaryLabel.Text = 'Enter an RGF and a generalized pattern.'
    $exportButton.Enabled = $false
}

function Get-CombinedJobLog {
    param([int]$Attempts = 1)
    $standard = ''
    $errors = ''
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentLogPath) -and (Test-Path -LiteralPath $script:CurrentLogPath)) {
        try { $standard = Read-TextFileAutoEncoding -Path $script:CurrentLogPath -Attempts $Attempts }
        catch { if ($Attempts -gt 1) { throw } }
    }
    if (-not [string]::IsNullOrWhiteSpace($script:CurrentErrorLogPath) -and (Test-Path -LiteralPath $script:CurrentErrorLogPath)) {
        try { $errors = Read-TextFileAutoEncoding -Path $script:CurrentErrorLogPath -Attempts $Attempts }
        catch { if ($Attempts -gt 1) { throw } }
    }
    if ([string]::IsNullOrWhiteSpace($errors)) { return $standard }
    if ([string]::IsNullOrWhiteSpace($standard)) { return $errors }
    return $standard.TrimEnd() + "`r`n`r`n--- standard error ---`r`n" + $errors
}

function Start-NativeEngineJob {
    param(
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments,
        [bool]$ShowLog = $true
    )

    if ($null -ne $script:RunningProcess) {
        if (-not $script:RunningProcess.HasExited) {
            throw 'A calculation or engine operation is already running.'
        }
        try {
            $script:RunningProcess.WaitForExit()
            $script:RunningProcess.Dispose()
        }
        catch { }
        $script:RunningProcess = $null
    }
    if (-not (Test-Path -LiteralPath $script:EnginePath)) {
        throw "The native engine is missing: $($script:EnginePath)"
    }

    $tempRoot = Join-Path $script:SessionRoot 'NativeJobs'
    [void](New-Item -ItemType Directory -Force -Path $tempRoot)
    $token = [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $tempRoot ("job_$token.out.log")
    $stderrPath = Join-Path $tempRoot ("job_$token.err.log")
    Write-Utf8NoBom -Path $stdoutPath -Text ''
    Write-Utf8NoBom -Path $stderrPath -Text ''

    $argumentLine = (($Arguments | ForEach-Object { Quote-WindowsArgument ([string]$_) }) -join ' ')
    $process = Start-Process `
        -FilePath $script:EnginePath `
        -ArgumentList $argumentLine `
        -WorkingDirectory $script:AppDirectory `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -WindowStyle Hidden `
        -PassThru
    if ($null -eq $process) { throw 'Windows could not start the native engine.' }

    $script:RunningProcess = $process
    $script:CurrentOperation = $Operation
    $script:CurrentLogPath = $stdoutPath
    $script:CurrentErrorLogPath = $stderrPath
    $script:CurrentScriptPath = ''
    $script:CurrentShowLog = $ShowLog
    $script:LastLogLength = -1
    $script:LastErrorLogLength = -1
    $script:RunStarted = Get-Date
    if ($ShowLog) {
        $logBox.Clear()
        $resultsTabs.SelectedTab = $logTab
    }
    Set-RunningState -Running $true -Message "$Operation is running in the native Windows engine..."
    $pollTimer.Start()
}

function Load-ResultTables {
    if ([string]::IsNullOrWhiteSpace($script:CurrentOutputPrefix)) { return }
    $totalsPath = $script:CurrentOutputPrefix + '_totals.csv'
    $byMaxPath = $script:CurrentOutputPrefix + '_by_max.csv'

    # Windows can report completion a fraction of a second before DrvFS releases
    # the final Windows-side file handle.  Read through a shared stream and
    # retry briefly instead of treating that normal delay as a GUI failure.
    $totalsRows = @(Import-CsvWithRetry -Path $totalsPath -Attempts 50 -DelayMilliseconds 100)
    $byMaxRows = @(Import-CsvWithRetry -Path $byMaxPath -Attempts 50 -DelayMilliseconds 100)
    if ($totalsRows.Count -eq 0) { throw "The temporary totals table is empty: $totalsPath" }
    if ($byMaxRows.Count -eq 0) { throw "The temporary refined table is empty: $byMaxPath" }

    $script:TotalsDataTable = Convert-CsvToDataTable -Rows $totalsRows
    $script:ByMaxDataTable = Convert-CsvToDataTable -Rows $byMaxRows

    if ($script:TotalsDataTable -isnot [System.Data.DataTable]) {
        throw 'Internal GUI error: the totals CSV was not converted to a DataTable.'
    }
    if ($script:ByMaxDataTable -isnot [System.Data.DataTable]) {
        throw 'Internal GUI error: the refined CSV was not converted to a DataTable.'
    }

    Update-ClassInfo
    Initialize-OeisFooter

    $totalsGrid.DataSource = $null
    $byMaxGrid.DataSource = $null
    $totalsGrid.AutoGenerateColumns = $true
    $byMaxGrid.AutoGenerateColumns = $true
    # DataView is the most reliable WinForms binding target under Windows
    # PowerShell 5.1 and remains valid for both one- and multi-class tables.
    # The displayed totals table contains one non-exported OEIS footer row.
    $totalsGrid.DataSource = $script:TotalsDisplayDataTable.DefaultView
    $byMaxGrid.DataSource = $script:ByMaxDataTable.DefaultView
    $totalsGrid.AutoResizeColumns([System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells)
    $byMaxGrid.AutoResizeColumns([System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells)
    $totalsGrid.Refresh()
    $byMaxGrid.Refresh()
    Style-OeisFooterRow

    $statisticsPath = $script:CurrentOutputPrefix + '_statistics.csv'
    if (Test-Path -LiteralPath $statisticsPath) {
        $script:StatisticsRows = @(Import-CsvWithRetry -Path $statisticsPath -Attempts 50 -DelayMilliseconds 100)
    }
    else {
        $script:StatisticsRows = @()
    }
    if ($script:StatisticsRows.Count -gt 0) {
        Update-StatisticsSelectors
    }
    else {
        Clear-StatisticsDisplay
    }
    Update-PatternQueryControls
    $exportButton.Enabled = $true
    Start-OeisLookups
}

function Set-ListLoading {
    param([bool]$Loading, [string]$Message)
    if ($null -eq $script:ListForm -or $script:ListForm.IsDisposed) { return }
    if ($Loading) {
        $script:ListPreviousButton.Enabled = $false
        $script:ListNextButton.Enabled = $false
        $script:ListLoadAllButton.Enabled = $false
        $script:ListDiagramButton.Enabled = $false
        if ($null -ne $script:DiagramForm -and -not $script:DiagramForm.IsDisposed) {
            $script:DiagramPreviousButton.Enabled = $false
            $script:DiagramNextButton.Enabled = $false
        }
    }
    elseif ($null -ne $script:ListState) {
        $total = [System.Numerics.BigInteger]::Parse([string]$script:ListState.Request.TotalCount)
        $end = ([System.Numerics.BigInteger]($script:ListState.Offset)) + $script:ListState.Words.Count
        $script:ListPreviousButton.Enabled = ($script:ListState.Offset -gt 0)
        $script:ListNextButton.Enabled = ($end -lt $total)
        $script:ListLoadAllButton.Enabled = ($total -gt $script:ListState.Words.Count -or $script:ListState.Offset -gt 0)
        $script:ListDiagramButton.Enabled = ($script:ListItems.Items.Count -gt 0 -and $script:ListState.Request.N -gt 0)
        if ($null -ne $script:DiagramForm -and -not $script:DiagramForm.IsDisposed) { Update-DiagramView }
    }
    $script:ListStatus.Text = $Message
}

function Complete-PendingListPage {
    if ($null -eq $script:PendingListPage) { return }
    $pending = $script:PendingListPage
    $script:PendingListPage = $null
    try {
        $words = if (Test-Path -LiteralPath $pending.OutputPath) {
            $pageText = Read-TextFileAutoEncoding -Path $pending.OutputPath -Attempts 40 -DelayMilliseconds 100
            @($pageText -split '\r?\n' | Where-Object { $_.Length -gt 0 })
        } else { @() }
        Remove-Item -LiteralPath $pending.OutputPath -Force -ErrorAction SilentlyContinue
        Apply-ListPage -Offset $pending.Offset -Words $words -AfterLoad $pending.AfterLoad
    }
    catch {
        Set-ListLoading -Loading $false -Message ('Could not load RGFs: ' + $_.Exception.Message)
        throw
    }
}

function Finish-CurrentJob {
    param([int]$ExitCode)

    $pollTimer.Stop()
    if (-not $script:CurrentShowLog -and $ExitCode -ne 0) { $logBox.Clear() }
    try {
        $finalLog = Get-CombinedJobLog -Attempts 40
        if ($script:CurrentShowLog -or $ExitCode -ne 0) { Append-LogText $finalLog }
    }
    catch {
        if ($script:CurrentShowLog -or $ExitCode -ne 0) {
            $logBox.AppendText("`r`n[The final log could not be read: $($_.Exception.Message)]`r`n")
        }
    }

    $elapsed = if ($null -ne $script:RunStarted) {
        [Math]::Round(((Get-Date) - $script:RunStarted).TotalSeconds, 1)
    } else { 0 }
    $operation = $script:CurrentOperation
    $script:RunningProcess.Dispose()
    $script:RunningProcess = $null

    if ($ExitCode -eq 0) {
        switch ($operation) {
            'Enumeration' {
                Load-ResultTables
                $resultsTabs.SelectedTab = $totalsTab
                $catalogText = if ($script:CurrentStoreAll) { ' Full avoiding-RGF catalogues are stored temporarily for this session.' } else { '' }
                Set-RunningState -Running $false -Message "Enumeration completed in $elapsed seconds.$catalogText Right-click a data row to inspect avoiding RGFs."
            }
            'List avoiders' {
                Set-RunningState -Running $false -Message "RGF page generated in $elapsed seconds."
                Complete-PendingListPage
            }
            'Inspect pattern' {
                Complete-PatternInspection
                Set-RunningState -Running $false -Message "Pattern inspection completed in $elapsed seconds."
            }
            'Pattern query' {
                Complete-PatternQuery
                Set-RunningState -Running $false -Message "Pattern occurrence distribution completed in $elapsed seconds."
            }
            'Install' {
                Set-RunningState -Running $false -Message "Engine installed and validated successfully in $elapsed seconds."
            }
            default {
                Set-RunningState -Running $false -Message "$operation completed successfully in $elapsed seconds."
            }
        }
    }
    else {
        $explanation = "The native engine returned exit code $ExitCode."
        Set-RunningState -Running $false -Message "$operation stopped. $explanation See the Log tab."
        if ($operation -eq 'List avoiders') {
            Set-ListLoading -Loading $false -Message "Listing stopped. $explanation"
            $script:PendingListPage = $null
        }
        elseif ($operation -eq 'Inspect pattern') {
            $script:PendingInspection = $null
        }
        elseif ($operation -eq 'Pattern query') {
            $script:PendingPatternQuery = $null
        }
        $resultsTabs.SelectedTab = $logTab
        [System.Windows.Forms.MessageBox]::Show(
            "$operation did not complete successfully.`r`n`r`n$explanation`r`n`r`nOpen the Log tab for the exact error.",
            'RGF Pattern Laboratory',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CurrentScriptPath)) {
        Remove-Item -LiteralPath $script:CurrentScriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-CurrentJob {
    if ($null -eq $script:RunningProcess -or $script:RunningProcess.HasExited) { return }
    $pidToStop = $script:RunningProcess.Id
    try {
        # taskkill /T also terminates any worker process descendants, although
        # the current engine normally uses threads rather than child processes.
        & "$env:WINDIR\System32\taskkill.exe" /PID $pidToStop /T /F 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0 -and -not $script:RunningProcess.HasExited) {
            $script:RunningProcess.Kill()
        }
    }
    catch {
        try { $script:RunningProcess.Kill() } catch { }
    }
    $statusLabel.Text = 'Cancellation requested. Completed result rows are preserved only if they had already been flushed.'
}

function Get-CatalogFilePath {
    param([int]$ClassIndex, [int]$N, [int]$K)
    $name = 'class_{0:D3}_n_{1:D3}_k_{2:D3}.txt' -f $ClassIndex, $N, $K
    return Join-Path $script:CurrentCatalogDirectory $name
}

function Read-CatalogPage {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [Parameter(Mandatory = $true)][uint64]$Offset,
        [Parameter(Mandatory = $true)][uint64]$Limit
    )

    $files = New-Object System.Collections.Generic.List[string]
    if ($Request.N -eq 0) {
        $files.Add((Get-CatalogFilePath -ClassIndex $Request.ClassIndex -N 0 -K 0))
    }
    elseif ($Request.K -gt 0) {
        $files.Add((Get-CatalogFilePath -ClassIndex $Request.ClassIndex -N $Request.N -K $Request.K))
    }
    else {
        for ($k = 1; $k -le $Request.N; $k++) {
            $files.Add((Get-CatalogFilePath -ClassIndex $Request.ClassIndex -N $Request.N -K $k))
        }
    }

    $words = New-Object System.Collections.Generic.List[string]
    [uint64]$skip = $Offset
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $reader = New-Object System.IO.StreamReader($file, [System.Text.Encoding]::UTF8, $true)
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                if ($skip -gt 0) { $skip--; continue }
                $words.Add([string]$line)
                if ($Limit -ne 0 -and [uint64]$words.Count -ge $Limit) { return $words.ToArray() }
            }
        }
        finally { $reader.Dispose() }
    }
    return $words.ToArray()
}

function Request-AvoiderPage {
    param(
        [Parameter(Mandatory = $true)][uint64]$Offset,
        [Parameter(Mandatory = $true)][uint64]$Limit,
        [string]$AfterLoad = ''
    )

    if ($null -eq $script:ListState) { return }
    if ($null -ne $script:RunningProcess -and -not $script:RunningProcess.HasExited) {
        [System.Windows.Forms.MessageBox]::Show(
            'Another engine operation is running. Cancel it or let it finish first.',
            'RGF Pattern Laboratory'
        ) | Out-Null
        return
    }

    Set-ListLoading -Loading $true -Message 'Generating the requested avoiding RGFs...'
    if ($script:CurrentStoreAll -and (Test-Path -LiteralPath $script:CurrentCatalogDirectory)) {
        try {
            $words = @(Read-CatalogPage -Request $script:ListState.Request -Offset $Offset -Limit $Limit)
            Apply-ListPage -Offset $Offset -Words $words -AfterLoad $AfterLoad
        }
        catch {
            Set-ListLoading -Loading $false -Message ('Catalogue read failed: ' + $_.Exception.Message)
        }
        return
    }

    $outputPath = Join-Path $script:CurrentRunDirectory ('page_' + [Guid]::NewGuid().ToString('N') + '.txt')
    $request = $script:ListState.Request

    $script:PendingListPage = [pscustomobject]@{
        Offset = $Offset
        Limit = $Limit
        AfterLoad = $AfterLoad
        OutputPath = $outputPath
    }

    $arguments = @(
        '--family', 'rgf',
        '--classes', $script:CurrentClassFile,
        '--list-class', [string]$request.ClassIndex,
        '--list-n', [string]$request.N,
        '--offset', [string]$Offset,
        '--limit', [string]$Limit,
        '--list-output', $outputPath
    )
    if ($request.K -gt 0) { $arguments += @('--k', [string]$request.K) }
    try {
        Start-NativeEngineJob -Operation 'List avoiders' -Arguments $arguments -ShowLog $false
    }
    catch {
        $script:PendingListPage = $null
        Set-ListLoading -Loading $false -Message ('Could not start listing: ' + $_.Exception.Message)
    }
}

function Apply-ListPage {
    param(
        [Parameter(Mandatory = $true)][uint64]$Offset,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Words,
        [string]$AfterLoad = ''
    )

    if ($null -eq $script:ListState -or $null -eq $script:ListForm -or $script:ListForm.IsDisposed) { return }
    $script:ListState.Offset = $Offset
    $script:ListState.Words = @($Words)
    Refresh-ListDisplay
    if ($script:ListItems.Items.Count -gt 0) { $script:ListItems.SelectedIndex = 0 }

    $total = [System.Numerics.BigInteger]::Parse([string]$script:ListState.Request.TotalCount)
    if ($Words.Count -eq 0) {
        $rangeText = 'No avoiding RGFs in this range.'
        $end = [System.Numerics.BigInteger]$Offset
    }
    else {
        $start = ([System.Numerics.BigInteger]$Offset) + 1
        $end = ([System.Numerics.BigInteger]$Offset) + $Words.Count
        $rangeText = "Showing $start-$end of $total"
    }
    $script:ListStatus.Text = $rangeText
    $script:ListPreviousButton.Enabled = ($Offset -gt 0)
    $script:ListNextButton.Enabled = ($end -lt $total)
    $script:ListLoadAllButton.Enabled = ($total -gt $Words.Count -or $Offset -gt 0)
    $script:ListDiagramButton.Enabled = ($Words.Count -gt 0 -and $script:ListState.Request.N -gt 0)

    switch ($AfterLoad) {
        'OpenDiagram' { Open-DiagramViewer -StartIndex 0 }
        'DiagramFirst' {
            if ($null -ne $script:DiagramState) { $script:DiagramState.LocalIndex = 0; Update-DiagramView }
        }
        'DiagramLast' {
            if ($null -ne $script:DiagramState) {
                $script:DiagramState.LocalIndex = [Math]::Max(0, $Words.Count - 1)
                Update-DiagramView
            }
        }
        'DiagramJump' {
            if ($null -ne $script:DiagramState) {
                [uint64]$target = $script:DiagramState.PendingTarget
                $local = [int]($target - 1 - $Offset)
                $script:DiagramState.LocalIndex = [Math]::Max(0, [Math]::Min($Words.Count - 1, $local))
                Update-DiagramView
            }
        }
        default {
            if ($null -ne $script:DiagramState -and $null -ne $script:DiagramForm -and -not $script:DiagramForm.IsDisposed) {
                $script:DiagramState.LocalIndex = 0
                Update-DiagramView
            }
        }
    }
}

function Export-DisplayedWords {
    if ($null -eq $script:ListState -or $script:ListState.Words.Count -eq 0) { return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $safeClassName = ([string]$script:ListState.Request.ClassName -replace '[^A-Za-z0-9_-]', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safeClassName)) { $safeClassName = 'class' }
    $dialog.FileName = ('rgfs_n{0}_{1}.txt' -f $script:ListState.Request.N, $safeClassName)
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        [System.IO.File]::WriteAllLines($dialog.FileName, [string[]]$script:ListState.Words, (New-Object System.Text.UTF8Encoding($false)))
    }
    $dialog.Dispose()
}

function Open-AvoiderBrowser {
    param(
        [Parameter(Mandatory = $true)]$Request,
        [bool]$OpenDiagram = $false
    )

    Close-BrowserWindows
    $script:ListState = [pscustomobject]@{
        Request = $Request
        Offset = [uint64]0
        PageSize = [uint64]100
        Words = @()
        StatisticId = ''
    }

    $window = New-Object System.Windows.Forms.Form
    $window.Text = "Avoiding RGFs: $($Request.ClassName), n=$($Request.N)" + $(if ($Request.K -gt 0) { ", k=$($Request.K)" } else { '' })
    $window.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $window.Size = New-Object System.Drawing.Size(760, 735)
    $window.MinimumSize = New-Object System.Drawing.Size(620, 565)
    $window.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:ListForm = $window

    $heading = New-Label -Text ("{0} avoiding RGFs in {1}" -f $Request.TotalCount, $Request.ClassName) -X 15 -Y 12 -Width 710 -Height 28
    $heading.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    $window.Controls.Add($heading)
    $scope = if ($Request.K -gt 0) { "Length $($Request.N), $($Request.K) blocks" } else { "Length $($Request.N), all block counts" }
    $scopeLabel = New-Label -Text $scope -X 16 -Y 42 -Width 700
    $scopeLabel.ForeColor = [System.Drawing.Color]::DimGray
    $window.Controls.Add($scopeLabel)

    $statLabel = New-Label -Text 'Display statistic:' -X 16 -Y 76 -Width 112
    $window.Controls.Add($statLabel)
    $statCombo = New-Object System.Windows.Forms.ComboBox
    $statCombo.Location = New-Object System.Drawing.Point(130, 72)
    $statCombo.Size = New-Object System.Drawing.Size(350, 25)
    $statCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    [void]$statCombo.Items.Add('None - show RGFs only')
    $script:ListStatisticIds = @('')
    foreach ($statistic in $script:StatisticCatalog) {
        [void]$statCombo.Items.Add([string]$statistic.Label)
        $script:ListStatisticIds += [string]$statistic.Id
    }
    $statCombo.SelectedIndex = 0
    $window.Controls.Add($statCombo)
    $script:ListStatisticCombo = $statCombo

    $items = New-Object System.Windows.Forms.ListBox
    $items.Location = New-Object System.Drawing.Point(16, 105)
    $items.Size = New-Object System.Drawing.Size(710, 500)
    $items.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $items.Font = New-Object System.Drawing.Font('Consolas', 10)
    $items.HorizontalScrollbar = $true
    $window.Controls.Add($items)
    $script:ListItems = $items

    $status = New-Label -Text 'Loading...' -X 16 -Y 612 -Width 710 -Height 24
    $status.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $status.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
    $window.Controls.Add($status)
    $script:ListStatus = $status

    $previous = New-Object System.Windows.Forms.Button
    $previous.Text = 'Previous 100'
    $previous.Location = New-Object System.Drawing.Point(16, 645)
    $previous.Size = New-Object System.Drawing.Size(105, 30)
    $previous.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($previous)
    $script:ListPreviousButton = $previous

    $next = New-Object System.Windows.Forms.Button
    $next.Text = 'Next 100'
    $next.Location = New-Object System.Drawing.Point(128, 645)
    $next.Size = New-Object System.Drawing.Size(105, 30)
    $next.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($next)
    $script:ListNextButton = $next

    $all = New-Object System.Windows.Forms.Button
    $all.Text = 'Load all'
    $all.Location = New-Object System.Drawing.Point(240, 645)
    $all.Size = New-Object System.Drawing.Size(88, 30)
    $all.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($all)
    $script:ListLoadAllButton = $all

    $diagram = New-Object System.Windows.Forms.Button
    $diagram.Text = 'Diagram...'
    $diagram.Location = New-Object System.Drawing.Point(335, 645)
    $diagram.Size = New-Object System.Drawing.Size(95, 30)
    $diagram.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($diagram)
    $script:ListDiagramButton = $diagram

    $export = New-Object System.Windows.Forms.Button
    $export.Text = 'Export shown...'
    $export.Location = New-Object System.Drawing.Point(437, 645)
    $export.Size = New-Object System.Drawing.Size(112, 30)
    $export.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($export)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Location = New-Object System.Drawing.Point(638, 645)
    $close.Size = New-Object System.Drawing.Size(88, 30)
    $close.Anchor = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($close)

    $statCombo.Add_SelectedIndexChanged({
        if ($null -eq $script:ListState) { return }
        $index = $script:ListStatisticCombo.SelectedIndex
        if ($index -ge 0 -and $index -lt $script:ListStatisticIds.Count) {
            $script:ListState.StatisticId = [string]$script:ListStatisticIds[$index]
            Refresh-ListDisplay
            if ($null -ne $script:DiagramForm -and -not $script:DiagramForm.IsDisposed) { Update-DiagramView }
        }
    })

    $previous.Add_Click({
        [uint64]$offset = $script:ListState.Offset
        [uint64]$page = $script:ListState.PageSize
        $newOffset = if ($offset -gt $page) { $offset - $page } else { [uint64]0 }
        Request-AvoiderPage -Offset $newOffset -Limit $page
    })
    $next.Add_Click({
        [uint64]$newOffset = $script:ListState.Offset + [uint64]($script:ListState.Words.Count)
        Request-AvoiderPage -Offset $newOffset -Limit $script:ListState.PageSize
    })
    $all.Add_Click({
        $total = [System.Numerics.BigInteger]::Parse([string]$script:ListState.Request.TotalCount)
        if ($total -gt 50000) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "This will load $total RGFs into one Windows control and may use substantial time and memory. Continue?",
                'Load all RGFs',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
        Request-AvoiderPage -Offset 0 -Limit 0
    })
    $diagram.Add_Click({
        $index = if ($script:ListItems.SelectedIndex -ge 0) { $script:ListItems.SelectedIndex } else { 0 }
        Open-DiagramViewer -StartIndex $index
    })
    $items.Add_DoubleClick({
        if ($script:ListItems.SelectedIndex -ge 0) { Open-DiagramViewer -StartIndex $script:ListItems.SelectedIndex }
    })
    $export.Add_Click({ Export-DisplayedWords })
    $close.Add_Click({ $window.Close() })
    $window.Add_FormClosed({
        if ($null -ne $script:DiagramForm -and -not $script:DiagramForm.IsDisposed) { $script:DiagramForm.Close() }
        $script:ListForm = $null
        $script:ListState = $null
        $script:ListStatisticCombo = $null
    })

    $window.Show($form)
    Request-AvoiderPage -Offset 0 -Limit 100 -AfterLoad $(if ($OpenDiagram) { 'OpenDiagram' } else { '' })
}

function Parse-WordValues {
    param([Parameter(Mandatory = $true)][string]$Word)
    if ($Word -eq 'epsilon') { return @() }
    if ($Word -match '[,\s]') {
        return @($Word.Trim() -split '[,\s]+' | Where-Object { $_.Length -gt 0 } | ForEach-Object { [int]$_ })
    }
    $values = New-Object System.Collections.Generic.List[int]
    foreach ($character in $Word.ToCharArray()) { $values.Add([int]::Parse([string]$character)) }
    return $values.ToArray()
}


function Format-PositionSet {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Positions)
    if ($Positions.Count -eq 0) { return '{}' }
    return '{' + (($Positions | ForEach-Object { [string]$_ }) -join ',') + '}'
}

function Get-WordStatisticValue {
    param(
        [Parameter(Mandatory = $true)][string]$Word,
        [Parameter(Mandatory = $true)][string]$StatisticId
    )
    $values = @(Parse-WordValues -Word $Word)
    $n = $values.Count
    if ([string]::IsNullOrWhiteSpace($StatisticId)) { return '' }
    $asc = 0; $des = 0; $wasc = 0; $wdes = 0; $levels = 0
    $maj = 0; $wmaj = 0
    $ascSet = @(); $desSet = @(); $wascSet = @(); $wdesSet = @()
    for ($i = 0; $i + 1 -lt $n; $i++) {
        $left = [int]$values[$i]; $right = [int]$values[$i + 1]; $position = $i + 1
        if ($left -lt $right) { $asc++; $ascSet += $position }
        if ($left -gt $right) { $des++; $maj += $position; $desSet += $position }
        if ($left -le $right) { $wasc++; $wascSet += $position }
        if ($left -ge $right) { $wdes++; $wmaj += $position; $wdesSet += $position }
        if ($left -eq $right) { $levels++ }
    }
    $inv = 0; $coinv = 0
    for ($i = 0; $i -lt $n; $i++) {
        for ($j = $i + 1; $j -lt $n; $j++) {
            if ([int]$values[$i] -gt [int]$values[$j]) { $inv++ }
            elseif ([int]$values[$i] -lt [int]$values[$j]) { $coinv++ }
        }
    }
    $peakSet = @(); $valleySet = @()
    for ($i = 1; $i + 1 -lt $n; $i++) {
        $a = [int]$values[$i - 1]; $b = [int]$values[$i]; $c = [int]$values[$i + 1]
        if ($a -lt $b -and $b -gt $c) { $peakSet += ($i + 1) }
        if ($a -gt $b -and $b -lt $c) { $valleySet += ($i + 1) }
    }
    $fixedSet = @(); $letterSum = 0; $maximum = 0
    for ($i = 0; $i -lt $n; $i++) {
        $value = [int]$values[$i]
        $letterSum += $value
        if ($value -gt $maximum) { $maximum = $value }
        if ($value -eq $i + 1) { $fixedSet += ($i + 1) }
    }
    $evaluation = @()
    $singletons = 0; $repeated = 0
    for ($letter = 1; $letter -le $maximum; $letter++) {
        $frequency = 0
        foreach ($value in $values) { if ([int]$value -eq $letter) { $frequency++ } }
        $evaluation += $frequency
        if ($frequency -eq 1) { $singletons++ }
        elseif ($frequency -ge 2) { $repeated++ }
    }
    $leftPeaks = $peakSet.Count
    if ($n -ge 2 -and [int]$values[0] -gt [int]$values[1]) { $leftPeaks++ }

    switch ($StatisticId) {
        'ascents' { return [string]$asc }
        'descents' { return [string]$des }
        'weak_ascents' { return [string]$wasc }
        'weak_descents' { return [string]$wdes }
        'equal_adjacencies' { return [string]$levels }
        'major_index' { return [string]$maj }
        'weak_major_index' { return [string]$wmaj }
        'inversions' { return [string]$inv }
        'coinversions' { return [string]$coinv }
        'peaks' { return [string]$peakSet.Count }
        'valleys' { return [string]$valleySet.Count }
        'left_peaks' { return [string]$leftPeaks }
        'fixed_points' { return [string]$fixedSet.Count }
        'letter_sum' { return [string]$letterSum }
        'maximum' { return [string]$maximum }
        'strict_increasing_runs' { return [string]$(if ($n -eq 0) { 0 } else { $wdes + 1 }) }
        'strict_decreasing_runs' { return [string]$(if ($n -eq 0) { 0 } else { $wasc + 1 }) }
        'weak_increasing_runs' { return [string]$(if ($n -eq 0) { 0 } else { $des + 1 }) }
        'weak_decreasing_runs' { return [string]$(if ($n -eq 0) { 0 } else { $asc + 1 }) }
        'singleton_letters' { return [string]$singletons }
        'repeated_letters' { return [string]$repeated }
        'ascent_set' { return (Format-PositionSet -Positions $ascSet) }
        'descent_set' { return (Format-PositionSet -Positions $desSet) }
        'weak_ascent_set' { return (Format-PositionSet -Positions $wascSet) }
        'weak_descent_set' { return (Format-PositionSet -Positions $wdesSet) }
        'peak_set' { return (Format-PositionSet -Positions $peakSet) }
        'valley_set' { return (Format-PositionSet -Positions $valleySet) }
        'fixed_point_set' { return (Format-PositionSet -Positions $fixedSet) }
        'evaluation' { return '(' + (($evaluation | ForEach-Object { [string]$_ }) -join ',') + ')' }
        default { return '' }
    }
}

function Refresh-ListDisplay {
    if ($null -eq $script:ListItems -or $null -eq $script:ListState) { return }
    $selected = $script:ListItems.SelectedIndex
    $statisticId = [string]$script:ListState.StatisticId
    $label = if ([string]::IsNullOrWhiteSpace($statisticId)) { '' } else { Get-StatisticLabel -Id $statisticId }
    $script:ListItems.BeginUpdate()
    try {
        $script:ListItems.Items.Clear()
        foreach ($rawWord in $script:ListState.Words) {
            $word = [string]$rawWord
            $display = $word
            if (-not [string]::IsNullOrWhiteSpace($statisticId)) {
                $value = Get-WordStatisticValue -Word $word -StatisticId $statisticId
                $display = "$word    | $label = $value"
            }
            [void]$script:ListItems.Items.Add($display)
        }
    }
    finally { $script:ListItems.EndUpdate() }
    if ($script:ListItems.Items.Count -gt 0) {
        $script:ListItems.SelectedIndex = [Math]::Max(0, [Math]::Min($script:ListItems.Items.Count - 1, $selected))
    }
}

function Draw-PermutationDiagram {
    param($Sender, $EventArgs)
    if ($null -eq $script:DiagramState -or $null -eq $script:ListState) { return }
    if ($script:ListState.Words.Count -eq 0) { return }

    $g = $EventArgs.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::White)
    $n = [int]$script:ListState.Request.N
    if ($n -le 0) {
        $font = New-Object System.Drawing.Font('Segoe UI', 18)
        $g.DrawString('empty word', $font, [System.Drawing.Brushes]::Black, 30, 30)
        $font.Dispose()
        return
    }

    $word = [string]$script:ListState.Words[$script:DiagramState.LocalIndex]
    $values = @(Parse-WordValues -Word $word)
    if ($values.Count -ne $n) { return }

    $marginLeft = 46.0
    $marginTop = 22.0
    $marginBottom = 42.0
    $availableWidth = [Math]::Max(20.0, $Sender.ClientSize.Width - $marginLeft - 20.0)
    $availableHeight = [Math]::Max(20.0, $Sender.ClientSize.Height - $marginTop - $marginBottom)
    $side = [Math]::Min($availableWidth, $availableHeight)
    $cell = $side / $n
    $left = $marginLeft
    $top = $marginTop

    $gridPen = New-Object System.Drawing.Pen([System.Drawing.Color]::LightGray, 1)
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.5)
    try {
        for ($i = 0; $i -le $n; $i++) {
            $x = [single]($left + $i * $cell)
            $y = [single]($top + $i * $cell)
            $g.DrawLine($gridPen, $x, [single]$top, $x, [single]($top + $side))
            $g.DrawLine($gridPen, [single]$left, $y, [single]($left + $side), $y)
        }
        $g.DrawRectangle($borderPen, [single]$left, [single]$top, [single]$side, [single]$side)

        $dotDiameter = [Math]::Max(5.0, [Math]::Min(13.0, $cell * 0.42))
        for ($position = 1; $position -le $n; $position++) {
            $value = [int]$values[$position - 1]
            $xCenter = $left + ($position - 0.5) * $cell
            $yCenter = $top + ($n - $value + 0.5) * $cell
            $g.FillEllipse(
                [System.Drawing.Brushes]::Black,
                [single]($xCenter - $dotDiameter / 2),
                [single]($yCenter - $dotDiameter / 2),
                [single]$dotDiameter,
                [single]$dotDiameter
            )
        }

        if ($n -le 20) {
            $labelFont = New-Object System.Drawing.Font('Segoe UI', 8)
            try {
                for ($i = 1; $i -le $n; $i++) {
                    $text = [string]$i
                    $size = $g.MeasureString($text, $labelFont)
                    $x = $left + ($i - 0.5) * $cell - $size.Width / 2
                    $g.DrawString($text, $labelFont, [System.Drawing.Brushes]::Black, [single]$x, [single]($top + $side + 5))
                    $y = $top + ($n - $i + 0.5) * $cell - $size.Height / 2
                    $g.DrawString($text, $labelFont, [System.Drawing.Brushes]::Black, [single]($left - $size.Width - 7), [single]$y)
                }
            }
            finally { $labelFont.Dispose() }
        }
    }
    finally {
        $gridPen.Dispose()
        $borderPen.Dispose()
    }
}

function Update-DiagramView {
    if ($null -eq $script:DiagramState -or $null -eq $script:DiagramForm -or $script:DiagramForm.IsDisposed) { return }
    if ($null -eq $script:ListState -or $script:ListState.Words.Count -eq 0) { return }
    $index = [Math]::Max(0, [Math]::Min($script:ListState.Words.Count - 1, [int]$script:DiagramState.LocalIndex))
    $script:DiagramState.LocalIndex = $index
    $word = [string]$script:ListState.Words[$index]
    $global = ([System.Numerics.BigInteger]($script:ListState.Offset)) + $index + 1
    $total = $script:ListState.Request.TotalCount
    $script:DiagramWordLabel.Text = "w = $word"
    $statisticId = [string]$script:ListState.StatisticId
    if ([string]::IsNullOrWhiteSpace($statisticId)) {
        $script:DiagramStatisticLabel.Text = ''
    }
    else {
        $script:DiagramStatisticLabel.Text = ('{0} = {1}' -f (Get-StatisticLabel -Id $statisticId), (Get-WordStatisticValue -Word $word -StatisticId $statisticId))
    }
    $script:DiagramIndexLabel.Text = "$global of $total"
    $script:DiagramPreviousButton.Enabled = ($global -gt 1)
    $script:DiagramNextButton.Enabled = ($global -lt [System.Numerics.BigInteger]::Parse([string]$total))
    $script:DiagramPanel.Invalidate()
}

function Move-Diagram {
    param([int]$Delta)
    if ($null -eq $script:DiagramState -or $null -eq $script:ListState) { return }
    $local = [int]$script:DiagramState.LocalIndex
    if ($Delta -lt 0) {
        if ($local -gt 0) {
            $script:DiagramState.LocalIndex = $local - 1
            Update-DiagramView
        }
        elseif ($script:ListState.Offset -gt 0) {
            [uint64]$page = $script:ListState.PageSize
            [uint64]$newOffset = if ($script:ListState.Offset -gt $page) { $script:ListState.Offset - $page } else { 0 }
            Request-AvoiderPage -Offset $newOffset -Limit $page -AfterLoad 'DiagramLast'
        }
    }
    elseif ($Delta -gt 0) {
        if ($local + 1 -lt $script:ListState.Words.Count) {
            $script:DiagramState.LocalIndex = $local + 1
            Update-DiagramView
        }
        else {
            $currentEnd = ([System.Numerics.BigInteger]($script:ListState.Offset)) + $script:ListState.Words.Count
            $total = [System.Numerics.BigInteger]::Parse([string]$script:ListState.Request.TotalCount)
            if ($currentEnd -lt $total) {
                [uint64]$newOffset = $script:ListState.Offset + [uint64]($script:ListState.Words.Count)
                Request-AvoiderPage -Offset $newOffset -Limit $script:ListState.PageSize -AfterLoad 'DiagramFirst'
            }
        }
    }
}

function Jump-Diagram {
    if ($null -eq $script:DiagramState -or $null -eq $script:ListState) { return }
    [uint64]$target = 0
    if (-not [uint64]::TryParse($script:DiagramJumpBox.Text.Trim(), [ref]$target) -or $target -lt 1) {
        [System.Windows.Forms.MessageBox]::Show('Enter a positive integer index.', 'Jump to RGF') | Out-Null
        return
    }
    $total = [System.Numerics.BigInteger]::Parse([string]$script:ListState.Request.TotalCount)
    if ([System.Numerics.BigInteger]$target -gt $total) {
        [System.Windows.Forms.MessageBox]::Show("The largest index is $total.", 'Jump to RGF') | Out-Null
        return
    }
    [uint64]$zero = $target - 1
    [uint64]$start = $script:ListState.Offset
    [uint64]$endExclusive = $start + [uint64]($script:ListState.Words.Count)
    if ($zero -ge $start -and $zero -lt $endExclusive) {
        $script:DiagramState.LocalIndex = [int]($zero - $start)
        Update-DiagramView
        return
    }
    [uint64]$page = $script:ListState.PageSize
    [uint64]$pageStart = $zero - ($zero % $page)
    $script:DiagramState.PendingTarget = $target
    Request-AvoiderPage -Offset $pageStart -Limit $page -AfterLoad 'DiagramJump'
}

function Open-DiagramViewer {
    param([int]$StartIndex = 0)
    if ($null -eq $script:ListState -or $script:ListState.Words.Count -eq 0) { return }
    if ($script:ListState.Request.N -le 0) {
        [System.Windows.Forms.MessageBox]::Show('The empty word has no nontrivial diagram.', 'RGF diagram') | Out-Null
        return
    }
    if ($null -ne $script:DiagramForm -and -not $script:DiagramForm.IsDisposed) { $script:DiagramForm.Close() }

    $script:DiagramState = [pscustomobject]@{
        LocalIndex = [Math]::Max(0, [Math]::Min($script:ListState.Words.Count - 1, $StartIndex))
        PendingTarget = [uint64]0
    }
    $window = New-Object System.Windows.Forms.Form
    $window.Text = "RGF diagram: $($script:ListState.Request.ClassName)"
    $window.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $window.Size = New-Object System.Drawing.Size(760, 820)
    $window.MinimumSize = New-Object System.Drawing.Size(560, 640)
    $window.KeyPreview = $true
    $window.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $script:DiagramForm = $window

    $wordLabel = New-Label -Text '' -X 18 -Y 12 -Width 710 -Height 28
    $wordLabel.Font = New-Object System.Drawing.Font('Consolas', 12)
    $window.Controls.Add($wordLabel)
    $script:DiagramWordLabel = $wordLabel

    $statisticLabel = New-Label -Text '' -X 18 -Y 41 -Width 710 -Height 22
    $statisticLabel.ForeColor = [System.Drawing.Color]::DarkSlateGray
    $window.Controls.Add($statisticLabel)
    $script:DiagramStatisticLabel = $statisticLabel

    $indexLabel = New-Label -Text '' -X 18 -Y 63 -Width 300
    $indexLabel.ForeColor = [System.Drawing.Color]::DimGray
    $window.Controls.Add($indexLabel)
    $script:DiagramIndexLabel = $indexLabel

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point(16, 90)
    $panel.Size = New-Object System.Drawing.Size(710, 630)
    $panel.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
    $panel.BackColor = [System.Drawing.Color]::White
    $panel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $panel.Add_Paint({ param($sender, $eventArgs) Draw-PermutationDiagram -Sender $sender -EventArgs $eventArgs })
    $window.Controls.Add($panel)
    $script:DiagramPanel = $panel

    $previous = New-Object System.Windows.Forms.Button
    $previous.Text = 'Previous'
    $previous.Location = New-Object System.Drawing.Point(16, 736)
    $previous.Size = New-Object System.Drawing.Size(90, 30)
    $previous.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($previous)
    $script:DiagramPreviousButton = $previous

    $next = New-Object System.Windows.Forms.Button
    $next.Text = 'Next'
    $next.Location = New-Object System.Drawing.Point(112, 736)
    $next.Size = New-Object System.Drawing.Size(90, 30)
    $next.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($next)
    $script:DiagramNextButton = $next

    $jumpLabel = New-Label -Text 'Jump to index:' -X 230 -Y 741 -Width 95
    $jumpLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($jumpLabel)
    $jumpBox = New-Object System.Windows.Forms.TextBox
    $jumpBox.Location = New-Object System.Drawing.Point(325, 738)
    $jumpBox.Size = New-Object System.Drawing.Size(105, 24)
    $jumpBox.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($jumpBox)
    $script:DiagramJumpBox = $jumpBox
    $jumpButton = New-Object System.Windows.Forms.Button
    $jumpButton.Text = 'Go'
    $jumpButton.Location = New-Object System.Drawing.Point(437, 736)
    $jumpButton.Size = New-Object System.Drawing.Size(55, 30)
    $jumpButton.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($jumpButton)

    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Location = New-Object System.Drawing.Point(636, 736)
    $close.Size = New-Object System.Drawing.Size(90, 30)
    $close.Anchor = [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $window.Controls.Add($close)

    $previous.Add_Click({ Move-Diagram -Delta -1 })
    $next.Add_Click({ Move-Diagram -Delta 1 })
    $jumpButton.Add_Click({ Jump-Diagram })
    $jumpBox.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Jump-Diagram; $e.SuppressKeyPress = $true } })
    $close.Add_Click({ $window.Close() })
    $window.Add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Left) { Move-Diagram -Delta -1; $e.Handled = $true }
        elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Right) { Move-Diagram -Delta 1; $e.Handled = $true }
    })
    $window.Add_FormClosed({ $script:DiagramForm = $null; $script:DiagramState = $null; $script:DiagramStatisticLabel = $null })
    $window.Show($script:ListForm)
    Update-DiagramView
}


function Show-PatternSyntaxHelp {
    $text = @"
Classical patterns
  13442
  classical:13442

Consecutive patterns
  consecutive:121
  con:121
All selected positions in an occurrence must be consecutive.

Vincular patterns
  vincular:1232|2
The bond after pattern position 2 requires the second and third selected
positions to be adjacent in the word.

  vincular:12321|1,3
requires adjacency after pattern positions 1 and 3.

Patterns with ranks 10 or above use spaces or commas, for example
  vincular:1 3 10 4|1,3

A mixed avoidance basis is allowed:
  my_class = 13442 + consecutive:121 + vincular:1232|2
"@
    [System.Windows.Forms.MessageBox]::Show(
        $text,
        'Generalized pattern syntax',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function Complete-PatternInspection {
    if ($null -eq $script:PendingInspection) { return }
    $pending = $script:PendingInspection
    $script:PendingInspection = $null
    $summaryRows = @(Import-CsvWithRetry -Path $pending.SummaryPath -Attempts 40 -DelayMilliseconds 100)
    $occurrenceRows = @(Import-CsvWithRetry -Path $pending.OccurrencesPath -Attempts 40 -DelayMilliseconds 100)
    $script:InspectionSummaryRows = $summaryRows
    $script:InspectionOccurrenceRows = $occurrenceRows
    if ($summaryRows.Count -gt 0) {
        $row = $summaryRows[0]
        $containsText = if ([string]$row.contains -eq 'true') { 'contains' } else { 'avoids' }
        $script:InspectionWord = [string]$row.word
        $inspectionSummaryLabel.Text = ('The RGF {0} {1} {2}. Total occurrences: {3}; listed: {4}.' -f
            $row.word, $containsText, $row.pattern, $row.total_occurrences, $row.listed_occurrences)
    }
    else {
        $inspectionSummaryLabel.Text = 'Inspection completed, but the summary was empty.'
    }
    $table = Convert-CsvToDataTable -Rows $occurrenceRows
    $inspectionGrid.DataSource = $null
    $inspectionGrid.AutoGenerateColumns = $true
    $inspectionGrid.DataSource = $table.DefaultView
    $inspectionGrid.AutoResizeColumns([System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells)
    $inspectionExportButton.Enabled = ($occurrenceRows.Count -gt 0)
    $resultsTabs.SelectedTab = $patternToolsTab
}

function Start-PatternInspection {
    try {
        $word = $inspectionWordBox.Text.Trim()
        $pattern = $inspectionPatternBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($word)) { throw 'Enter an RGF in one-line notation.' }
        if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Enter a classical, consecutive, or vincular pattern.' }
        $toolDirectory = Join-Path $script:SessionRoot 'PatternTools'
        [void](New-Item -ItemType Directory -Force -Path $toolDirectory)
        $prefix = Join-Path $toolDirectory ('inspection_' + [Guid]::NewGuid().ToString('N'))
        $script:PendingInspection = [pscustomobject]@{
            SummaryPath = $prefix + '_summary.csv'
            OccurrencesPath = $prefix + '_occurrences.csv'
        }
        $limit = Get-CommittedNumericValue -Control $inspectionLimitBox -DisplayName 'Occurrence list limit'
        $arguments = @(
            '--inspect-word', $word,
            '--inspect-pattern', $pattern,
            '--inspect-output', $prefix,
            '--inspect-limit', [string]$limit
        )
        Start-NativeEngineJob -Operation 'Inspect pattern' -Arguments $arguments -ShowLog $false
    }
    catch {
        $script:PendingInspection = $null
        [System.Windows.Forms.MessageBox]::Show((Format-GuiError -Record $_), 'Pattern inspection error') | Out-Null
    }
}

function Export-InspectionOccurrences {
    if ($script:InspectionOccurrenceRows.Count -eq 0) { return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FileName = 'pattern_occurrences.csv'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $csv = ($script:InspectionOccurrenceRows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
        Write-Utf8NoBom -Path $dialog.FileName -Text ($csv + "`r`n")
    }
    $dialog.Dispose()
}

function Update-PatternQueryKChoices {
    if ($null -eq $patternQueryKCombo) { return }
    $previous = if ($patternQueryKCombo.SelectedIndex -ge 0) { [string]$patternQueryKCombo.SelectedItem } else { 'All block counts' }
    $patternQueryKCombo.Items.Clear()
    [void]$patternQueryKCombo.Items.Add('All block counts')
    if ($patternQueryNCombo.SelectedIndex -ge 0) {
        $n = [int][string]$patternQueryNCombo.SelectedItem
        if ($n -gt 0) {
            if ($script:CurrentOnlyK -gt 0 -and $script:CurrentOnlyK -le $n) {
                [void]$patternQueryKCombo.Items.Add("blocks k = $($script:CurrentOnlyK)")
            }
            elseif ($null -ne $script:ByMaxDataTable) {
                $seen = @()
                foreach ($row in $script:ByMaxDataTable.Rows) {
                    if ([int][string]$row['n'] -eq $n) {
                        $k = [int][string]$row['k']
                        if ($seen -notcontains $k) { $seen += $k }
                    }
                }
                foreach ($k in @($seen | Sort-Object)) { [void]$patternQueryKCombo.Items.Add("blocks k = $k") }
            }
        }
    }
    $found = $patternQueryKCombo.Items.IndexOf($previous)
    $patternQueryKCombo.SelectedIndex = if ($found -ge 0) { $found } else { 0 }
}

function Update-PatternQueryControls {
    if ($null -eq $patternQueryClassCombo) { return }
    $patternQueryClassCombo.Items.Clear()
    $patternQueryNCombo.Items.Clear()
    foreach ($class in $script:CurrentClasses) { [void]$patternQueryClassCombo.Items.Add([string]$class.Name) }
    if ($null -ne $script:TotalsDataTable) {
        foreach ($row in $script:TotalsDataTable.Rows) { [void]$patternQueryNCombo.Items.Add([string]$row['n']) }
    }
    if ($patternQueryClassCombo.Items.Count -gt 0) { $patternQueryClassCombo.SelectedIndex = 0 }
    if ($patternQueryNCombo.Items.Count -gt 0) { $patternQueryNCombo.SelectedIndex = $patternQueryNCombo.Items.Count - 1 }
    Update-PatternQueryKChoices
    $patternQueryButton.Enabled = ($null -eq $script:RunningProcess -and $patternQueryClassCombo.Items.Count -gt 0)
}

function Prepare-PatternQuery {
    param([Parameter(Mandatory = $true)]$Request)
    $resultsTabs.SelectedTab = $patternToolsTab
    for ($i = 0; $i -lt $script:CurrentClasses.Count; $i++) {
        if ([int]$script:CurrentClasses[$i].Index -eq [int]$Request.ClassIndex) {
            $patternQueryClassCombo.SelectedIndex = $i
            break
        }
    }
    $nIndex = $patternQueryNCombo.Items.IndexOf([string]$Request.N)
    if ($nIndex -ge 0) { $patternQueryNCombo.SelectedIndex = $nIndex }
    Update-PatternQueryKChoices
    if ([int]$Request.K -gt 0) {
        $kIndex = $patternQueryKCombo.Items.IndexOf("blocks k = $($Request.K)")
        if ($kIndex -ge 0) { $patternQueryKCombo.SelectedIndex = $kIndex }
    }
    $patternQueryPatternBox.Focus()
}

function Complete-PatternQuery {
    if ($null -eq $script:PendingPatternQuery) { return }
    $pending = $script:PendingPatternQuery
    $script:PendingPatternQuery = $null
    $rows = @(Import-CsvWithRetry -Path $pending.OutputPath -Attempts 50 -DelayMilliseconds 100)
    $selected = @()
    $desiredScope = if ($pending.K -gt 0) { 'exact' } else { 'total' }
    $desiredK = if ($pending.K -gt 0) { [string]$pending.K } else { '0' }
    [System.Numerics.BigInteger]$total = 0
    foreach ($row in $rows) {
        if ([string]$row.scope -eq $desiredScope -and [string]$row.k -eq $desiredK) {
            $selected += [pscustomobject]@{ Occurrences = [string]$row.occurrences; Count = [string]$row.count }
            [System.Numerics.BigInteger]$count = 0
            if ([System.Numerics.BigInteger]::TryParse([string]$row.count, [ref]$count)) { $total += $count }
        }
    }
    $script:PatternQueryRows = $selected
    $table = Convert-CsvToDataTable -Rows $selected
    $patternQueryGrid.DataSource = $null
    $patternQueryGrid.AutoGenerateColumns = $true
    $patternQueryGrid.DataSource = $table.DefaultView
    $patternQueryGrid.AutoResizeColumns([System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells)
    $scopeText = if ($pending.K -gt 0) { "$($pending.K) blocks" } else { 'all block counts' }
    $patternQuerySummaryLabel.Text = ('Occurrence distribution of {0} over {1}, n={2}, {3}. Total avoiding RGFs: {4}.' -f
        $pending.Pattern, $pending.ClassName, $pending.N, $scopeText, $total)
    $patternQueryExportButton.Enabled = ($selected.Count -gt 0)
    $resultsTabs.SelectedTab = $patternToolsTab
}

function Start-PatternQuery {
    try {
        if ($null -eq $script:TotalsDataTable -or [string]::IsNullOrWhiteSpace($script:CurrentClassFile)) {
            throw 'Run an enumeration first so that a current avoidance class is available.'
        }
        if ($patternQueryClassCombo.SelectedIndex -lt 0 -or $patternQueryNCombo.SelectedIndex -lt 0) {
            throw 'Choose a class and a length.'
        }
        $pattern = $patternQueryPatternBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($pattern)) { throw 'Enter a query pattern.' }
        $classIndex = $patternQueryClassCombo.SelectedIndex + 1
        $className = [string]$patternQueryClassCombo.SelectedItem
        $n = [int][string]$patternQueryNCombo.SelectedItem
        $k = 0
        if ($patternQueryKCombo.SelectedIndex -gt 0) {
            $k = [int](([string]$patternQueryKCombo.SelectedItem) -replace '^blocks k =\s*', '')
        }
        $outputPath = Join-Path $script:CurrentRunDirectory ('pattern_query_' + [Guid]::NewGuid().ToString('N') + '.csv')
        $script:PendingPatternQuery = [pscustomobject]@{
            OutputPath = $outputPath; ClassName = $className; N = $n; K = $k; Pattern = $pattern
        }
        $threads = Get-CommittedNumericValue -Control $threadsBox -DisplayName 'Threads'
        $arguments = @(
            '--family', 'rgf',
            '--classes', $script:CurrentClassFile,
            '--query-class', [string]$classIndex,
            '--query-n', [string]$n,
            '--query-pattern', $pattern,
            '--threads', [string]$threads,
            '--query-output', $outputPath
        )
        if ($k -gt 0) { $arguments += @('--k', [string]$k) }
        Start-NativeEngineJob -Operation 'Pattern query' -Arguments $arguments -ShowLog $false
    }
    catch {
        $script:PendingPatternQuery = $null
        [System.Windows.Forms.MessageBox]::Show((Format-GuiError -Record $_), 'Pattern-query error') | Out-Null
    }
}

function Export-PatternQueryDistribution {
    if ($script:PatternQueryRows.Count -eq 0) { return }
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
    $dialog.FileName = 'pattern_occurrence_distribution.csv'
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $csv = ($script:PatternQueryRows | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
        Write-Utf8NoBom -Path $dialog.FileName -Text ($csv + "`r`n")
    }
    $dialog.Dispose()
}

function Show-GridContextMenu {
    param(
        [Parameter(Mandatory = $true)]$Grid,
        [Parameter(Mandatory = $true)][int]$RowIndex,
        [Parameter(Mandatory = $true)][int]$X,
        [Parameter(Mandatory = $true)][int]$Y,
        [Parameter(Mandatory = $true)][bool]$ByMaximum
    )

    if ($script:CurrentClasses.Count -eq 0) { return }
    $row = $Grid.Rows[$RowIndex]
    $n = [int]$row.Cells[$Grid.Columns['n'].Index].Value
    $k = if ($ByMaximum) {
        [int]$row.Cells[$Grid.Columns['k'].Index].Value
    } elseif ($script:CurrentOnlyK -gt 0) {
        $script:CurrentOnlyK
    } else { 0 }

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    foreach ($class in $script:CurrentClasses) {
        if ($null -eq $Grid.Columns[$class.Column]) { continue }
        $count = [string]$row.Cells[$Grid.Columns[$class.Column].Index].Value
        $sub = New-Object System.Windows.Forms.ToolStripMenuItem
        $sub.Text = "$($class.Name)  ($count avoiding RGFs)"
        $request = [pscustomobject]@{
            ClassIndex = [int]$class.Index
            ClassName = [string]$class.Name
            N = $n
            K = $k
            TotalCount = $count
        }

        $listItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $listItem.Text = 'Show avoiding RGFs...'
        $listItem.Tag = $request
        $listItem.Enabled = ($count -ne '0')
        $listItem.Add_Click({ param($sender, $eventArgs) Open-AvoiderBrowser -Request $sender.Tag -OpenDiagram $false })
        [void]$sub.DropDownItems.Add($listItem)

        $diagramItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $diagramItem.Text = 'Show RGF diagrams...'
        $diagramItem.Tag = $request
        $diagramItem.Enabled = ($count -ne '0' -and $n -gt 0)
        $diagramItem.Add_Click({ param($sender, $eventArgs) Open-AvoiderBrowser -Request $sender.Tag -OpenDiagram $true })
        [void]$sub.DropDownItems.Add($diagramItem)

        $queryItem = New-Object System.Windows.Forms.ToolStripMenuItem
        $queryItem.Text = 'Analyse occurrences of another pattern...'
        $queryItem.Tag = $request
        $queryItem.Enabled = ($count -ne '0')
        $queryItem.Add_Click({ param($sender, $eventArgs) Prepare-PatternQuery -Request $sender.Tag })
        [void]$sub.DropDownItems.Add($queryItem)

        if ($script:CurrentStoreAll) {
            $storedItem = New-Object System.Windows.Forms.ToolStripMenuItem
            $storedItem.Text = 'Full list stored temporarily for this session'
            $storedItem.Enabled = $false
            [void]$sub.DropDownItems.Add($storedItem)
        }
        [void]$menu.Items.Add($sub)
    }
    $script:ActiveContextMenu = $menu
    $menu.Show($Grid, (New-Object System.Drawing.Point($X, $Y)))
}

# ---------------------------- Main window ----------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'RGF Pattern Laboratory 8.2'
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size(1180, 900)
$form.MinimumSize = New-Object System.Drawing.Size(1050, 780)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Label -Text 'RGF Pattern Laboratory 8.2' -X 18 -Y 12 -Width 500 -Height 34
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 18)
$form.Controls.Add($title)
$subtitle = New-Label -Text 'Exact RGF avoidance for classical, consecutive, and vincular patterns, streamed statistics, and occurrence analysis.' -X 20 -Y 47 -Width 700
$subtitle.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($subtitle)

$distroLabel = New-Label -Text 'Native Windows engine:' -X 755 -Y 19 -Width 155
$form.Controls.Add($distroLabel)
$distroCombo = New-Object System.Windows.Forms.ComboBox
$distroCombo.Location = New-Object System.Drawing.Point(910, 16)
$distroCombo.Size = New-Object System.Drawing.Size(230, 25)
$distroCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$distroCombo.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($distroCombo)

$installButton = New-Object System.Windows.Forms.Button
$installButton.Text = 'Open program folder'
$installButton.Location = New-Object System.Drawing.Point(755, 47)
$installButton.Size = New-Object System.Drawing.Size(180, 30)
$installButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($installButton)
$selfTestButton = New-Object System.Windows.Forms.Button
$selfTestButton.Text = 'Run self-test'
$selfTestButton.Location = New-Object System.Drawing.Point(945, 47)
$selfTestButton.Size = New-Object System.Drawing.Size(195, 30)
$selfTestButton.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($selfTestButton)

$classGroup = New-Object System.Windows.Forms.GroupBox
$classGroup.Text = 'RGF avoidance classes'
$classGroup.Location = New-Object System.Drawing.Point(18, 85)
$classGroup.Size = New-Object System.Drawing.Size(525, 310)
$form.Controls.Add($classGroup)
$classHelp = New-Label -Text 'One RGF class per line:  name = pattern + pattern + ...   (mixed pattern types allowed)' -X 12 -Y 23 -Width 475
$classGroup.Controls.Add($classHelp)
$classesBox = New-Object System.Windows.Forms.TextBox
$classesBox.Location = New-Object System.Drawing.Point(14, 48)
$classesBox.Size = New-Object System.Drawing.Size(495, 208)
$classesBox.Multiline = $true
$classesBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$classesBox.AcceptsReturn = $true
$classesBox.AcceptsTab = $true
$classesBox.WordWrap = $false
$classesBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$classesBox.Text = @"
# Bare patterns are classical.
avoid_121 = 121
# no_adjacent_121 = consecutive:121
# mixed_example = 121 + vincular:1232|2
"@
$classGroup.Controls.Add($classesBox)
$loadClassesButton = New-Object System.Windows.Forms.Button
$loadClassesButton.Text = 'Load...'
$loadClassesButton.Location = New-Object System.Drawing.Point(14, 265)
$loadClassesButton.Size = New-Object System.Drawing.Size(92, 27)
$classGroup.Controls.Add($loadClassesButton)
$saveClassesButton = New-Object System.Windows.Forms.Button
$saveClassesButton.Text = 'Save...'
$saveClassesButton.Location = New-Object System.Drawing.Point(113, 265)
$saveClassesButton.Size = New-Object System.Drawing.Size(92, 27)
$classGroup.Controls.Add($saveClassesButton)
$patternSyntaxButton = New-Object System.Windows.Forms.Button
$patternSyntaxButton.Text = 'Pattern syntax...'
$patternSyntaxButton.Location = New-Object System.Drawing.Point(218, 265)
$patternSyntaxButton.Size = New-Object System.Drawing.Size(125, 27)
$classGroup.Controls.Add($patternSyntaxButton)
$classSyntaxLabel = New-Label -Text 'Classical / consecutive / vincular' -X 351 -Y 270 -Width 155
$classSyntaxLabel.ForeColor = [System.Drawing.Color]::DimGray
$classGroup.Controls.Add($classSyntaxLabel)

$settingsGroup = New-Object System.Windows.Forms.GroupBox
$settingsGroup.Text = 'Run settings'
$settingsGroup.Location = New-Object System.Drawing.Point(558, 85)
$settingsGroup.Size = New-Object System.Drawing.Size(582, 310)
$settingsGroup.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($settingsGroup)
$settingsGroup.Controls.Add((New-Label -Text 'First n:' -X 14 -Y 29 -Width 70))
$minNBox = New-NumericBox -X 82 -Y 26 -Width 70 -Minimum 0 -Maximum 24 -Value 0
$settingsGroup.Controls.Add($minNBox)
$settingsGroup.Controls.Add((New-Label -Text 'Last n:' -X 172 -Y 29 -Width 65))
$maxNBox = New-NumericBox -X 236 -Y 26 -Width 70 -Minimum 0 -Maximum 24 -Value 10
$settingsGroup.Controls.Add($maxNBox)
$settingsGroup.Controls.Add((New-Label -Text 'Threads:' -X 325 -Y 29 -Width 65))
$detectedThreads = [Math]::Max(1, [Environment]::ProcessorCount)
$threadsBox = New-NumericBox -X 391 -Y 26 -Width 72 -Minimum 0 -Maximum 256 -Value $detectedThreads
$settingsGroup.Controls.Add($threadsBox)
$threadsNote = New-Label -Text "$detectedThreads logical processors detected" -X 390 -Y 51 -Width 180
$threadsNote.ForeColor = [System.Drawing.Color]::DimGray
$settingsGroup.Controls.Add($threadsNote)

$settingsGroup.Controls.Add((New-Label -Text 'Engine:' -X 14 -Y 70 -Width 65))
$engineCombo = New-Object System.Windows.Forms.ComboBox
$engineCombo.Location = New-Object System.Drawing.Point(82, 67)
$engineCombo.Size = New-Object System.Drawing.Size(112, 25)
$engineCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$engineCombo.Items.AddRange(@('auto', 'prefix', 'leaf'))
$engineCombo.SelectedIndex = 0
$settingsGroup.Controls.Add($engineCombo)
$settingsGroup.Controls.Add((New-Label -Text 'Only blocks k:' -X 215 -Y 70 -Width 113))
$onlyKBox = New-NumericBox -X 331 -Y 67 -Width 72 -Minimum 0 -Maximum 24 -Value 0
$settingsGroup.Controls.Add($onlyKBox)
$allKLabel = New-Label -Text '(0 = all)' -X 410 -Y 70 -Width 70
$allKLabel.ForeColor = [System.Drawing.Color]::DimGray
$settingsGroup.Controls.Add($allKLabel)

$collectStatisticsCheck = New-Object System.Windows.Forms.CheckBox
$collectStatisticsCheck.Text = 'Collect selected statistic distributions during enumeration'
$collectStatisticsCheck.Location = New-Object System.Drawing.Point(16, 105)
$collectStatisticsCheck.Size = New-Object System.Drawing.Size(355, 25)
$settingsGroup.Controls.Add($collectStatisticsCheck)
$selectStatisticsButton = New-Object System.Windows.Forms.Button
$selectStatisticsButton.Text = 'Select statistics...'
$selectStatisticsButton.Location = New-Object System.Drawing.Point(384, 101)
$selectStatisticsButton.Size = New-Object System.Drawing.Size(160, 29)
$settingsGroup.Controls.Add($selectStatisticsButton)
$statisticsSelectionLabel = New-Label -Text '' -X 35 -Y 131 -Width 515 -Height 23
$statisticsSelectionLabel.ForeColor = [System.Drawing.Color]::DimGray
$settingsGroup.Controls.Add($statisticsSelectionLabel)

$storeAllCheck = New-Object System.Windows.Forms.CheckBox
$storeAllCheck.Text = 'Temporarily store every avoiding RGF for unrestricted later browsing/checks'
$storeAllCheck.Location = New-Object System.Drawing.Point(16, 157)
$storeAllCheck.Size = New-Object System.Drawing.Size(540, 25)
$settingsGroup.Controls.Add($storeAllCheck)
$storeNote = New-Label -Text 'Usually unnecessary for distributions: selected statistics are streamed without retaining the RGFs.' -X 35 -Y 182 -Width 525 -Height 34
$storeNote.ForeColor = [System.Drawing.Color]::DimGray
$settingsGroup.Controls.Add($storeNote)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = 'Run enumeration'
$runButton.Location = New-Object System.Drawing.Point(14, 226)
$runButton.Size = New-Object System.Drawing.Size(165, 45)
$runButton.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$settingsGroup.Controls.Add($runButton)
$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Text = 'Cancel'
$cancelButton.Location = New-Object System.Drawing.Point(188, 226)
$cancelButton.Size = New-Object System.Drawing.Size(95, 45)
$cancelButton.Enabled = $false
$settingsGroup.Controls.Add($cancelButton)
$exportButton = New-Object System.Windows.Forms.Button
$exportButton.Text = 'Export current table...'
$exportButton.Location = New-Object System.Drawing.Point(292, 226)
$exportButton.Size = New-Object System.Drawing.Size(170, 45)
$exportButton.Enabled = $false
$settingsGroup.Controls.Add($exportButton)
$nothingSavedLabel = New-Label -Text 'Nothing is saved permanently unless you export.' -X 292 -Y 276 -Width 275
$nothingSavedLabel.ForeColor = [System.Drawing.Color]::DimGray
$settingsGroup.Controls.Add($nothingSavedLabel)

$resultsTabs = New-Object System.Windows.Forms.TabControl
$resultsTabs.Location = New-Object System.Drawing.Point(18, 408)
$resultsTabs.Size = New-Object System.Drawing.Size(1122, 410)
$resultsTabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($resultsTabs)

$totalsTab = New-Object System.Windows.Forms.TabPage
$totalsTab.Text = 'Totals by n'
$resultsTabs.TabPages.Add($totalsTab)
$totalsGrid = New-Object System.Windows.Forms.DataGridView
$totalsGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$totalsGrid.ReadOnly = $true
$totalsGrid.AllowUserToAddRows = $false
$totalsGrid.AllowUserToDeleteRows = $false
$totalsGrid.AllowUserToResizeRows = $false
$totalsGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$totalsGrid.MultiSelect = $false
$totalsGrid.RowHeadersVisible = $false
$totalsGrid.AutoSizeRowsMode = [System.Windows.Forms.DataGridViewAutoSizeRowsMode]::None
$totalsGrid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 248, 252)
$totalsTab.Controls.Add($totalsGrid)

$byMaxTab = New-Object System.Windows.Forms.TabPage
$byMaxTab.Text = 'Refined by number of blocks k'
$resultsTabs.TabPages.Add($byMaxTab)
$byMaxGrid = New-Object System.Windows.Forms.DataGridView
$byMaxGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$byMaxGrid.ReadOnly = $true
$byMaxGrid.AllowUserToAddRows = $false
$byMaxGrid.AllowUserToDeleteRows = $false
$byMaxGrid.AllowUserToResizeRows = $false
$byMaxGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$byMaxGrid.MultiSelect = $false
$byMaxGrid.RowHeadersVisible = $false
$byMaxGrid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 248, 252)
$byMaxTab.Controls.Add($byMaxGrid)

$statisticsTab = New-Object System.Windows.Forms.TabPage
$statisticsTab.Text = 'Statistics'
$resultsTabs.TabPages.Add($statisticsTab)
$statisticsTopPanel = New-Object System.Windows.Forms.Panel
$statisticsTopPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$statisticsTopPanel.Height = 78
$statisticsTab.Controls.Add($statisticsTopPanel)
$statisticsTopPanel.Controls.Add((New-Label -Text 'Class:' -X 10 -Y 12 -Width 45))
$statisticsClassCombo = New-Object System.Windows.Forms.ComboBox
$statisticsClassCombo.Location = New-Object System.Drawing.Point(55, 8)
$statisticsClassCombo.Size = New-Object System.Drawing.Size(190, 25)
$statisticsClassCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$statisticsClassCombo.Enabled = $false
$statisticsTopPanel.Controls.Add($statisticsClassCombo)
$statisticsTopPanel.Controls.Add((New-Label -Text 'Statistic:' -X 255 -Y 12 -Width 60))
$statisticsStatisticCombo = New-Object System.Windows.Forms.ComboBox
$statisticsStatisticCombo.Location = New-Object System.Drawing.Point(315, 8)
$statisticsStatisticCombo.Size = New-Object System.Drawing.Size(250, 25)
$statisticsStatisticCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$statisticsStatisticCombo.Enabled = $false
$statisticsTopPanel.Controls.Add($statisticsStatisticCombo)
$statisticsTopPanel.Controls.Add((New-Label -Text 'n:' -X 580 -Y 12 -Width 22))
$statisticsNCombo = New-Object System.Windows.Forms.ComboBox
$statisticsNCombo.Location = New-Object System.Drawing.Point(603, 8)
$statisticsNCombo.Size = New-Object System.Drawing.Size(70, 25)
$statisticsNCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$statisticsNCombo.Enabled = $false
$statisticsTopPanel.Controls.Add($statisticsNCombo)
$statisticsTopPanel.Controls.Add((New-Label -Text 'Scope:' -X 688 -Y 12 -Width 48))
$statisticsScopeCombo = New-Object System.Windows.Forms.ComboBox
$statisticsScopeCombo.Location = New-Object System.Drawing.Point(738, 8)
$statisticsScopeCombo.Size = New-Object System.Drawing.Size(155, 25)
$statisticsScopeCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$statisticsScopeCombo.Enabled = $false
$statisticsTopPanel.Controls.Add($statisticsScopeCombo)
$statisticsExportButton = New-Object System.Windows.Forms.Button
$statisticsExportButton.Text = 'Export distribution...'
$statisticsExportButton.Location = New-Object System.Drawing.Point(910, 7)
$statisticsExportButton.Size = New-Object System.Drawing.Size(155, 29)
$statisticsExportButton.Enabled = $false
$statisticsTopPanel.Controls.Add($statisticsExportButton)
$statisticsTotalLabel = New-Label -Text 'No statistic distributions have been collected.' -X 10 -Y 44 -Width 1055 -Height 25
$statisticsTotalLabel.ForeColor = [System.Drawing.Color]::DimGray
$statisticsTopPanel.Controls.Add($statisticsTotalLabel)
$statisticsGrid = New-Object System.Windows.Forms.DataGridView
$statisticsGrid.Dock = [System.Windows.Forms.DockStyle]::Fill
$statisticsGrid.ReadOnly = $true
$statisticsGrid.AllowUserToAddRows = $false
$statisticsGrid.AllowUserToDeleteRows = $false
$statisticsGrid.RowHeadersVisible = $false
$statisticsGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$statisticsGrid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 248, 252)
$statisticsTab.Controls.Add($statisticsGrid)
$statisticsTopPanel.BringToFront()

$patternToolsTab = New-Object System.Windows.Forms.TabPage
$patternToolsTab.Text = 'Pattern containment'
$resultsTabs.TabPages.Add($patternToolsTab)
$patternSplit = New-Object System.Windows.Forms.SplitContainer
$patternSplit.Dock = [System.Windows.Forms.DockStyle]::Fill
$patternSplit.Orientation = [System.Windows.Forms.Orientation]::Vertical
$patternSplit.Size = New-Object System.Drawing.Size(1080, 355)
$patternSplit.SplitterDistance = 540
$patternToolsTab.Controls.Add($patternSplit)

$inspectionGroup = New-Object System.Windows.Forms.GroupBox
$inspectionGroup.Text = 'Inspect one RGF'
$inspectionGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$patternSplit.Panel1.Controls.Add($inspectionGroup)
$inspectionGroup.Controls.Add((New-Label -Text 'Word:' -X 12 -Y 27 -Width 45))
$inspectionWordBox = New-Object System.Windows.Forms.TextBox
$inspectionWordBox.Location = New-Object System.Drawing.Point(58, 24)
$inspectionWordBox.Size = New-Object System.Drawing.Size(255, 24)
$inspectionWordBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$inspectionWordBox.Text = '12121'
$inspectionGroup.Controls.Add($inspectionWordBox)
$inspectionGroup.Controls.Add((New-Label -Text 'List limit:' -X 326 -Y 27 -Width 62))
$inspectionLimitBox = New-NumericBox -X 389 -Y 24 -Width 75 -Minimum 0 -Maximum 1000000 -Value 100
$inspectionGroup.Controls.Add($inspectionLimitBox)
$inspectionGroup.Controls.Add((New-Label -Text 'Pattern:' -X 12 -Y 62 -Width 55))
$inspectionPatternBox = New-Object System.Windows.Forms.TextBox
$inspectionPatternBox.Location = New-Object System.Drawing.Point(68, 59)
$inspectionPatternBox.Size = New-Object System.Drawing.Size(245, 24)
$inspectionPatternBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$inspectionPatternBox.Text = 'vincular:121|1'
$inspectionGroup.Controls.Add($inspectionPatternBox)
$inspectButton = New-Object System.Windows.Forms.Button
$inspectButton.Text = 'Inspect'
$inspectButton.Location = New-Object System.Drawing.Point(326, 56)
$inspectButton.Size = New-Object System.Drawing.Size(78, 29)
$inspectionGroup.Controls.Add($inspectButton)
$inspectionExportButton = New-Object System.Windows.Forms.Button
$inspectionExportButton.Text = 'Export...'
$inspectionExportButton.Location = New-Object System.Drawing.Point(410, 56)
$inspectionExportButton.Size = New-Object System.Drawing.Size(78, 29)
$inspectionExportButton.Enabled = $false
$inspectionGroup.Controls.Add($inspectionExportButton)
$inspectionSummaryLabel = New-Label -Text 'Enter an RGF and a generalized pattern.' -X 12 -Y 94 -Width 500 -Height 42
$inspectionSummaryLabel.ForeColor = [System.Drawing.Color]::DimGray
$inspectionGroup.Controls.Add($inspectionSummaryLabel)
$inspectionGrid = New-Object System.Windows.Forms.DataGridView
$inspectionGrid.Location = New-Object System.Drawing.Point(12, 138)
$inspectionGrid.Size = New-Object System.Drawing.Size(510, 220)
$inspectionGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$inspectionGrid.ReadOnly = $true
$inspectionGrid.AllowUserToAddRows = $false
$inspectionGrid.AllowUserToDeleteRows = $false
$inspectionGrid.RowHeadersVisible = $false
$inspectionGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$inspectionGroup.Controls.Add($inspectionGrid)

$patternQueryGroup = New-Object System.Windows.Forms.GroupBox
$patternQueryGroup.Text = 'Occurrence distribution within the current avoidance class'
$patternQueryGroup.Dock = [System.Windows.Forms.DockStyle]::Fill
$patternSplit.Panel2.Controls.Add($patternQueryGroup)
$patternQueryGroup.Controls.Add((New-Label -Text 'Class:' -X 12 -Y 27 -Width 42))
$patternQueryClassCombo = New-Object System.Windows.Forms.ComboBox
$patternQueryClassCombo.Location = New-Object System.Drawing.Point(55, 24)
$patternQueryClassCombo.Size = New-Object System.Drawing.Size(205, 25)
$patternQueryClassCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$patternQueryGroup.Controls.Add($patternQueryClassCombo)
$patternQueryGroup.Controls.Add((New-Label -Text 'n:' -X 270 -Y 27 -Width 20))
$patternQueryNCombo = New-Object System.Windows.Forms.ComboBox
$patternQueryNCombo.Location = New-Object System.Drawing.Point(291, 24)
$patternQueryNCombo.Size = New-Object System.Drawing.Size(58, 25)
$patternQueryNCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$patternQueryGroup.Controls.Add($patternQueryNCombo)
$patternQueryKCombo = New-Object System.Windows.Forms.ComboBox
$patternQueryKCombo.Location = New-Object System.Drawing.Point(358, 24)
$patternQueryKCombo.Size = New-Object System.Drawing.Size(150, 25)
$patternQueryKCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$patternQueryGroup.Controls.Add($patternQueryKCombo)
$patternQueryGroup.Controls.Add((New-Label -Text 'Query pattern:' -X 12 -Y 63 -Width 92))
$patternQueryPatternBox = New-Object System.Windows.Forms.TextBox
$patternQueryPatternBox.Location = New-Object System.Drawing.Point(105, 59)
$patternQueryPatternBox.Size = New-Object System.Drawing.Size(205, 24)
$patternQueryPatternBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$patternQueryPatternBox.Text = '121'
$patternQueryGroup.Controls.Add($patternQueryPatternBox)
$patternQueryButton = New-Object System.Windows.Forms.Button
$patternQueryButton.Text = 'Calculate'
$patternQueryButton.Location = New-Object System.Drawing.Point(319, 56)
$patternQueryButton.Size = New-Object System.Drawing.Size(85, 29)
$patternQueryButton.Enabled = $false
$patternQueryGroup.Controls.Add($patternQueryButton)
$patternQueryExportButton = New-Object System.Windows.Forms.Button
$patternQueryExportButton.Text = 'Export...'
$patternQueryExportButton.Location = New-Object System.Drawing.Point(411, 56)
$patternQueryExportButton.Size = New-Object System.Drawing.Size(80, 29)
$patternQueryExportButton.Enabled = $false
$patternQueryGroup.Controls.Add($patternQueryExportButton)
$patternQuerySummaryLabel = New-Label -Text 'Run an enumeration, then choose a class and query pattern.' -X 12 -Y 94 -Width 500 -Height 42
$patternQuerySummaryLabel.ForeColor = [System.Drawing.Color]::DimGray
$patternQueryGroup.Controls.Add($patternQuerySummaryLabel)
$patternQueryGrid = New-Object System.Windows.Forms.DataGridView
$patternQueryGrid.Location = New-Object System.Drawing.Point(12, 138)
$patternQueryGrid.Size = New-Object System.Drawing.Size(500, 220)
$patternQueryGrid.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$patternQueryGrid.ReadOnly = $true
$patternQueryGrid.AllowUserToAddRows = $false
$patternQueryGrid.AllowUserToDeleteRows = $false
$patternQueryGrid.RowHeadersVisible = $false
$patternQueryGrid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$patternQueryGroup.Controls.Add($patternQueryGrid)

$logTab = New-Object System.Windows.Forms.TabPage
$logTab.Text = 'Log'
$resultsTabs.TabPages.Add($logTab)
$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$logBox.ReadOnly = $true
$logBox.WordWrap = $false
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logTab.Controls.Add($logBox)

$statusLabel = New-Label -Text 'Ready. RGF Pattern Laboratory 8.2 is using the shared native Windows engine; Ubuntu and WSL are not required.' -X 20 -Y 827 -Width 1110 -Height 28
$statusLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
$statusLabel.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$form.Controls.Add($statusLabel)

# ---------------------------- Events ---------------------------------------
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 500
$pollTimer.Add_Tick({
    # Live-log display is best-effort; process completion polling must continue
    # even if antivirus software briefly locks one of the redirected files.
    try {
        $standardLength = 0L
        $errorLength = 0L
        if (-not [string]::IsNullOrWhiteSpace($script:CurrentLogPath) -and (Test-Path -LiteralPath $script:CurrentLogPath)) {
            $standardLength = (Get-Item -LiteralPath $script:CurrentLogPath).Length
        }
        if (-not [string]::IsNullOrWhiteSpace($script:CurrentErrorLogPath) -and (Test-Path -LiteralPath $script:CurrentErrorLogPath)) {
            $errorLength = (Get-Item -LiteralPath $script:CurrentErrorLogPath).Length
        }
        if ($standardLength -ne $script:LastLogLength -or $errorLength -ne $script:LastErrorLogLength) {
            try {
                $liveLog = Get-CombinedJobLog -Attempts 1
                $script:LastLogLength = $standardLength
                $script:LastErrorLogLength = $errorLength
                if ($script:CurrentShowLog) { Append-LogText $liveLog }
            }
            catch { }
        }
    }
    catch { }

    try {
        if ($null -ne $script:RunningProcess) {
            $elapsed = [Math]::Round(((Get-Date) - $script:RunStarted).TotalSeconds, 0)
            $statusLabel.Text = "$($script:CurrentOperation) is running... $elapsed seconds elapsed."
            if ($script:RunningProcess.HasExited) {
                $script:RunningProcess.WaitForExit()
                $completedExitCode = $script:RunningProcess.ExitCode
                Finish-CurrentJob -ExitCode $completedExitCode
            }
        }
    }
    catch {
        $details = Format-GuiError -Record $_
        $pollTimer.Stop()
        try {
            if ($null -ne $script:RunningProcess) { $script:RunningProcess.Dispose() }
        }
        catch { }
        $script:RunningProcess = $null
        Set-RunningState -Running $false -Message 'The calculation finished, but the GUI could not load its output. See the Log tab.'
        $logBox.AppendText("`r`n`r`nGUI completion error:`r`n$details`r`n")
        $resultsTabs.SelectedTab = $logTab
        [System.Windows.Forms.MessageBox]::Show(
            "The calculation process ended, but the GUI could not finish loading its output.`r`n`r`n$details",
            'RGF Pattern Laboratory error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})


$script:OeisLookupTimer = New-Object System.Windows.Forms.Timer
$script:OeisLookupTimer.Interval = 150
$script:OeisLookupTimer.Add_Tick({
    try { Complete-OeisLookupTick }
    catch {
        if ($null -ne $script:OeisLookupTimer) { $script:OeisLookupTimer.Stop() }
        $statusLabel.Text = 'The enumeration completed, but the OEIS footer lookup encountered an internal GUI error.'
    }
})

$installButton.Add_Click({
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList (Quote-WindowsArgument $script:AppDirectory) | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Open folder error') | Out-Null }
})

$selfTestButton.Add_Click({
    try {
        Start-NativeEngineJob -Operation 'Self-test' -Arguments @('--self-test') -ShowLog $true
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Self-test error') | Out-Null }
})

$patternSyntaxButton.Add_Click({ Show-PatternSyntaxHelp })
$selectStatisticsButton.Add_Click({ Show-StatisticSelectionDialog })
$collectStatisticsCheck.Add_CheckedChanged({
    if ($collectStatisticsCheck.Checked -and $script:SelectedStatisticIds.Count -eq 0) { Show-StatisticSelectionDialog }
})
$statisticsClassCombo.Add_SelectedIndexChanged({ if (-not $script:UpdatingStatisticsFilters) { Update-StatisticsScopeChoices } })
$statisticsStatisticCombo.Add_SelectedIndexChanged({ if (-not $script:UpdatingStatisticsFilters) { Update-StatisticsScopeChoices } })
$statisticsNCombo.Add_SelectedIndexChanged({ if (-not $script:UpdatingStatisticsFilters) { Update-StatisticsScopeChoices } })
$statisticsScopeCombo.Add_SelectedIndexChanged({ if (-not $script:UpdatingStatisticsFilters) { Refresh-StatisticsGrid } })
$statisticsExportButton.Add_Click({ Export-CurrentStatisticDistribution })
$inspectButton.Add_Click({ Start-PatternInspection })
$inspectionExportButton.Add_Click({ Export-InspectionOccurrences })
$inspectionWordBox.Add_KeyDown({ param($sender,$e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-PatternInspection; $e.SuppressKeyPress = $true } })
$inspectionPatternBox.Add_KeyDown({ param($sender,$e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-PatternInspection; $e.SuppressKeyPress = $true } })
$patternQueryNCombo.Add_SelectedIndexChanged({ Update-PatternQueryKChoices })
$patternQueryButton.Add_Click({ Start-PatternQuery })
$patternQueryExportButton.Add_Click({ Export-PatternQueryDistribution })
$patternQueryPatternBox.Add_KeyDown({ param($sender,$e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Start-PatternQuery; $e.SuppressKeyPress = $true } })

$runButton.Add_Click({
    try {
        [void]$form.ValidateChildren()
        $minN = Get-CommittedNumericValue -Control $minNBox -DisplayName 'First n'
        $maxN = Get-CommittedNumericValue -Control $maxNBox -DisplayName 'Last n'
        if ($minN -gt $maxN) { throw 'First n cannot exceed last n.' }
        $classText = $classesBox.Text.Trim()
        $meaningful = @(Get-ClassDisplayNames -Text $classText)
        if ($meaningful.Count -eq 0) { throw 'Enter at least one avoidance class.' }

        $collectStatistics = [bool]$collectStatisticsCheck.Checked
        $selectedStatistics = @()
        if ($collectStatistics) {
            $selectedStatistics = @($script:SelectedStatisticIds)
            if ($selectedStatistics.Count -eq 0) {
                throw 'Select at least one statistic, or untick statistic distributions.'
            }
        }

        $storeAll = [bool]$storeAllCheck.Checked
        if ($storeAll) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "Storing every avoiding RGF can be much slower than counting and can use many gigabytes for large classes.`r`n`r`nSelected statistic distributions do not require this option.`r`n`r`nThe catalogues will be temporary and deleted when this GUI closes or when you start a new run.`r`n`r`nContinue?",
                'Store every avoiding RGF',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        Clear-CurrentRun
        $runDirectory = Join-Path $script:SessionRoot ('Run_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
        [void](New-Item -ItemType Directory -Force -Path $runDirectory)
        $classFile = Join-Path $runDirectory 'classes.txt'
        $statisticsFile = Join-Path $runDirectory 'statistics.txt'
        $outputPrefix = Join-Path $runDirectory 'results'
        $catalogDirectory = Join-Path $runDirectory 'catalog'
        Write-Utf8NoBom -Path $classFile -Text (($classesBox.Text -replace "`r`n", "`n") + "`n")
        if ($collectStatistics) {
            Write-Utf8NoBom -Path $statisticsFile -Text (($selectedStatistics -join "`n") + "`n")
        }

        $script:CurrentRunDirectory = $runDirectory
        $script:CurrentOutputPrefix = $outputPrefix
        $script:CurrentClassFile = $classFile
        $script:CurrentStatisticsFile = if ($collectStatistics) { $statisticsFile } else { '' }
        $script:CurrentStatisticIds = @($selectedStatistics)
        $script:CurrentCatalogDirectory = $catalogDirectory
        $script:CurrentStoreAll = $storeAll
        $script:CurrentOnlyK = [int]$onlyKBox.Value
        $script:CurrentClassText = $classesBox.Text
        $script:TotalsDataTable = $null
        $script:ByMaxDataTable = $null
        $totalsGrid.DataSource = $null
        $byMaxGrid.DataSource = $null
        Clear-StatisticsDisplay
        $patternQueryGrid.DataSource = $null
        $patternQuerySummaryLabel.Text = 'Enumeration is running; pattern queries will be available afterwards.'
        $exportButton.Enabled = $false

        $engineMode = [string]$engineCombo.SelectedItem
        $threads = Get-CommittedNumericValue -Control $threadsBox -DisplayName 'Threads'
        $onlyK = Get-CommittedNumericValue -Control $onlyKBox -DisplayName 'Only number of blocks k'
        $script:CurrentOnlyK = $onlyK
        $classCount = $meaningful.Count
        $statisticCount = $selectedStatistics.Count

        $logBox.Text = @"
Results are being kept in a temporary GUI session.
Requested range: n=$minN through n=$maxN
Avoidance classes: $classCount
Threads: $threads; engine: $engineMode; only number of blocks k: $onlyK
Statistic distributions: $statisticCount

"@
        $arguments = @(
            '--family', 'rgf',
            '--min-n', [string]$minN,
            '--max-n', [string]$maxN,
            '--threads', [string]$threads,
            '--engine', $engineMode,
            '--classes', $classFile,
            '--output', $outputPrefix
        )
        if ($onlyK -gt 0) { $arguments += @('--k', [string]$onlyK) }
        if ($collectStatistics) { $arguments += @('--statistics', $statisticsFile) }
        if ($storeAll) { $arguments += @('--catalog-dir', $catalogDirectory) }
        Start-NativeEngineJob -Operation 'Enumeration' -Arguments $arguments -ShowLog $true
    }
    catch {
        $details = Format-GuiError -Record $_
        $logBox.Text = "Could not start enumeration.`r`n`r`n$details"
        $resultsTabs.SelectedTab = $logTab
        [System.Windows.Forms.MessageBox]::Show(
            $details,
            'Cannot start enumeration',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})

$cancelButton.Add_Click({ Stop-CurrentJob })

$exportButton.Add_Click({
    try {
        $source = ''
        $defaultName = ''
        if ($resultsTabs.SelectedTab -eq $totalsTab) {
            $source = $script:CurrentOutputPrefix + '_totals.csv'
            $defaultName = 'rgf_totals.csv'
        }
        elseif ($resultsTabs.SelectedTab -eq $byMaxTab) {
            $source = $script:CurrentOutputPrefix + '_by_max.csv'
            $defaultName = 'rgf_by_blocks.csv'
        }
        elseif ($resultsTabs.SelectedTab -eq $statisticsTab) {
            Export-CurrentStatisticDistribution
            return
        }
        elseif ($resultsTabs.SelectedTab -eq $patternToolsTab -and $script:PatternQueryRows.Count -gt 0) {
            Export-PatternQueryDistribution
            return
        }
        else {
            [System.Windows.Forms.MessageBox]::Show('Select Totals, Refined, Statistics, or a completed pattern distribution before exporting.', 'Export results') | Out-Null
            return
        }
        if (-not (Test-Path -LiteralPath $source)) { throw 'No completed table is available to export.' }
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        $dialog.FileName = $defaultName
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Copy-Item -LiteralPath $source -Destination $dialog.FileName -Force
            $statusLabel.Text = "Exported $($dialog.FileName)"
        }
        $dialog.Dispose()
    }
    catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Export error') | Out-Null }
})

$loadClassesButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.InitialDirectory = $script:AppDirectory
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $classesBox.Text = [System.IO.File]::ReadAllText($dialog.FileName)
    }
    $dialog.Dispose()
})

$saveClassesButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.FileName = 'rgf_classes.txt'
    $dialog.InitialDirectory = $script:AppDirectory
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Write-Utf8NoBom -Path $dialog.FileName -Text (($classesBox.Text -replace "`r`n", "`n") + "`n")
    }
    $dialog.Dispose()
})

$totalsGrid.Add_CellMouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        $sender.ClearSelection()
        $sender.Rows[$e.RowIndex].Selected = $true
        if ($e.ColumnIndex -ge 0) { $sender.CurrentCell = $sender.Rows[$e.RowIndex].Cells[$e.ColumnIndex] }
        if (Test-IsOeisFooterRow -Grid $sender -RowIndex $e.RowIndex) {
            Show-OeisContextMenu -Grid $sender -ColumnIndex $e.ColumnIndex -X $e.X -Y $e.Y
        }
        else {
            Show-GridContextMenu -Grid $sender -RowIndex $e.RowIndex -X $e.X -Y $e.Y -ByMaximum $false
        }
    }
})

$totalsGrid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    if (-not (Test-IsOeisFooterRow -Grid $sender -RowIndex $e.RowIndex)) { return }
    $columnName = [string]$sender.Columns[$e.ColumnIndex].Name
    if (-not $script:OeisResultsByColumn.ContainsKey($columnName)) { return }
    $result = $script:OeisResultsByColumn[$columnName]
    $url = if (-not [string]::IsNullOrWhiteSpace([string]$result.PrimaryUrl)) {
        [string]$result.PrimaryUrl
    } else { [string]$result.SearchUrl }
    Open-OeisUrl -Url $url
})

$totalsGrid.Add_DataBindingComplete({ Style-OeisFooterRow })
$byMaxGrid.Add_CellMouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        $sender.ClearSelection()
        $sender.Rows[$e.RowIndex].Selected = $true
        $sender.CurrentCell = $sender.Rows[$e.RowIndex].Cells[0]
        Show-GridContextMenu -Grid $sender -RowIndex $e.RowIndex -X $e.X -Y $e.Y -ByMaximum $true
    }
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($null -ne $script:RunningProcess -and -not $script:RunningProcess.HasExited) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
            'A calculation is running. Stop it and close the program?',
            'RGF Pattern Laboratory',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
            $eventArgs.Cancel = $true
            return
        }
        Stop-CurrentJob
    }
    Close-BrowserWindows
    Reset-OeisLookups
    if ($null -ne $script:OeisHttpClient) { try { $script:OeisHttpClient.Dispose() } catch { } }
    Remove-Item -LiteralPath $script:SessionRoot -Recurse -Force -ErrorAction SilentlyContinue
})

Update-StatisticSelectionSummary
Clear-StatisticsDisplay

[void]$distroCombo.Items.Add('PatternEngine.exe (RGF mode)')
$distroCombo.SelectedIndex = 0
$distroCombo.Enabled = $false
if (-not (Test-Path -LiteralPath $script:EnginePath)) {
    $statusLabel.Text = "The bundled native engine is missing: $($script:EnginePath)"
    $selfTestButton.Enabled = $false
    $runButton.Enabled = $false
}
else {
    $statusLabel.Text = 'Ready. Native RGF engine mode found; no Ubuntu, WSL, or compiler installation is required.'
}

[void]$form.ShowDialog()
$pollTimer.Dispose()
if ($null -ne $script:OeisLookupTimer) { $script:OeisLookupTimer.Dispose() }
$form.Dispose()
