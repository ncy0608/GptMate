$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$version = "0.3.0"
$runtimes = @(
    @{ Runtime = "win-x64"; Label = "Windows-x64" },
    @{ Runtime = "win-arm64"; Label = "Windows-ARM64" }
)

foreach ($item in $runtimes) {
    $publishDir = Join-Path $projectRoot "dist/$($item.Runtime)"
    $archive = Join-Path $projectRoot "dist/GptMate-v$version-$($item.Label).zip"
    dotnet publish (Join-Path $PSScriptRoot "GptMate.Windows.csproj") `
        --configuration Release `
        --runtime $item.Runtime `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:PublishReadyToRun=false `
        --output $publishDir
    Compress-Archive -Path "$publishDir/*" -DestinationPath $archive -Force
    $hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $(Split-Path -Leaf $archive)" | Set-Content "$archive.sha256" -Encoding ascii
    Write-Host "Created: $archive"
}
