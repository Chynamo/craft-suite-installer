[CmdletBinding()]
param([string]$Destination,[switch]$NoShortcuts,[switch]$VerifyOnly,[string]$PreviewImage,[string]$ShortcutRoot,[string]$GuiTestDestination,[string]$GuiTestImage,[int]$PreviewWidth=0)
$ErrorActionPreference='Stop'
$script:BundleRoot=$PSScriptRoot
$script:Manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'bundle.json') -Raw | ConvertFrom-Json
$script:ProgressCallback=$null
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Status([string]$message,[int]$percent){
 if($script:ProgressCallback){& $script:ProgressCallback $message $percent}else{Write-Host $message}
}
function Inside([string]$path,[string]$root){
 $p=[IO.Path]::GetFullPath($path).TrimEnd('\');$r=[IO.Path]::GetFullPath($root).TrimEnd('\')
 if(-not $p.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)){throw "Unsafe path: $p"}
 return $p
}
function Reject-Links([string]$path){
 $p=[IO.Path]::GetFullPath($path)
 while($p){
  if(Test-Path -LiteralPath $p){if((Get-Item -LiteralPath $p).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "Choose a normal folder, not a linked folder: $p"}}
  $next=Split-Path $p -Parent;if($next -eq $p){break};$p=$next
 }
}
function File-Hash([string]$path){
 $stream=[IO.File]::OpenRead($path);$hash=[Security.Cryptography.SHA256]::Create()
 try{return [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-','')}
 finally{$stream.Dispose();$hash.Dispose()}
}
function Verify-Payloads {
 if(-not [Environment]::Is64BitOperatingSystem){throw 'These apps require 64-bit Windows.'}
 $n=0
 foreach($app in $script:Manifest.apps){
  $n++;Status ('Checking '+$app.name+'...') ([int](20*$n/$script:Manifest.apps.Count))
  $zip=Inside (Join-Path $script:BundleRoot $app.payload) $script:BundleRoot
  if(-not(Test-Path -LiteralPath $zip -PathType Leaf)){throw 'Missing payload. Extract the whole ZIP first: '+$app.payload}
  if((Get-Item -LiteralPath $zip).Length -ne $app.payloadBytes -or (File-Hash $zip) -ne $app.sha256){throw 'Integrity check failed for '+$app.name+'. Use an intact copy of the bundle; no apps were installed.'}
  $archive=[IO.Compression.ZipFile]::OpenRead($zip)
  try{
   foreach($entry in $archive.Entries){
    if($entry.FullName -match '(^[\/]|^[A-Za-z]:|(^|[\/])\.\.([\/]|$))'){throw 'Unsafe archive path in '+$app.name}
   }
  }finally{$archive.Dispose()}
 }
 foreach($file in $script:Manifest.supportFiles){
  $path=Inside (Join-Path $script:BundleRoot $file.path) $script:BundleRoot
  if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (File-Hash $path) -ne $file.sha256){throw 'Support file integrity check failed: '+$file.path}
 }
}
function Verify-Installed($app,[string]$versionRoot){
 foreach($file in $app.files){
  $path=Inside (Join-Path $versionRoot $file.path) $versionRoot
  if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'Missing installed file: '+$path}
  if((Get-Item -LiteralPath $path).Length -ne $file.bytes -or (File-Hash $path) -ne $file.sha256){throw 'Existing file differs and was preserved: '+$path+'. Choose another installation folder.'}
 }
}
function Save-Json($value,[string]$path){$value | ConvertTo-Json -Depth 18 | Set-Content -LiteralPath $path -Encoding UTF8}
function Make-Link([string]$path,[string]$target,[string]$argsForApp=''){
 $shell=New-Object -ComObject WScript.Shell
 if(Test-Path -LiteralPath $path){$existing=$shell.CreateShortcut($path);if($existing.TargetPath -ne $target){throw 'An unrelated shortcut already exists and was preserved: '+$path}}
 $link=$shell.CreateShortcut($path);$link.TargetPath=$target;$link.Arguments=$argsForApp;$link.WorkingDirectory=Split-Path $target;$link.IconLocation=$target+',0';$link.Description='Official unmodified '+[IO.Path]::GetFileNameWithoutExtension($target)+' release';$link.Save()
}
function Install-Suite([string]$chosen,[bool]$externalShortcuts){
 $target=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($chosen)).TrimEnd('\')
 if(-not [IO.Path]::IsPathRooted($chosen) -or $target -eq [IO.Path]::GetPathRoot($target).TrimEnd('\')){throw 'Choose a full folder path, not the root of a drive.'}
 foreach($system in @($env:WINDIR,$env:ProgramFiles,${env:ProgramFiles(x86)})){
  if($system -and ($target -eq $system -or $target.StartsWith($system+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Choose your own writable folder, such as D:\Craft Suite. Administrator installation is not needed.'}
 }
 Reject-Links $target
 if($target -eq $script:BundleRoot -or $target.StartsWith($script:BundleRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Choose an installation folder outside the extracted installer.'}
 $receiptPath=Join-Path $target 'suite-installation.json'
 $existingReceipt=$null
 if(Test-Path -LiteralPath $target){
  if(Test-Path -LiteralPath $receiptPath){$existingReceipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json;if($existingReceipt.bundleId -ne $script:Manifest.bundleId){throw 'This folder belongs to another installation.'}}
  elseif(@(Get-ChildItem -LiteralPath $target -Force).Count){throw 'This folder contains other files. Choose an empty folder; your existing files will not be replaced.'}
 }
 Verify-Payloads
 # Check existing versions before any mutations, preserving modified files and additional user data.
 foreach($app in $script:Manifest.apps){
  $versionRoot=Inside (Join-Path $target ('Apps\'+$app.name+'\'+$app.version)) $target
  if(Test-Path -LiteralPath $versionRoot){Reject-Links $versionRoot;Verify-Installed $app $versionRoot}
 }
 $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($target))
 $needed=[long]$script:Manifest.installedBytes+[long]$script:Manifest.largestAppBytes+268435456
 if($drive.AvailableFreeSpace -lt $needed -and -not $existingReceipt){throw 'Not enough free space on the chosen drive. Allow at least 2 GB for installation.'}
 New-Item -ItemType Directory -Path $target -Force | Out-Null
 $receipt=[ordered]@{bundleId=$script:Manifest.bundleId;bundleVersion=$script:Manifest.bundleVersion;destination=$target;status='installing';installed=@();reused=@();shortcuts=@();errors=@()}
 Save-Json $receipt $receiptPath
 $stage=$null
 try{
  $n=0
  foreach($app in $script:Manifest.apps){
   $n++;Status ('Installing '+$app.name+' '+$app.version+'...') (20+[int](65*$n/$script:Manifest.apps.Count))
   $versionRoot=Inside (Join-Path $target ('Apps\'+$app.name+'\'+$app.version)) $target
   if(Test-Path -LiteralPath $versionRoot){$receipt.reused+= $app.name}
   else{
    $stage=Inside (Join-Path $target ('.craft-install-'+[guid]::NewGuid().ToString('N'))) $target
    New-Item -ItemType Directory -Path $stage | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $script:BundleRoot $app.payload),$stage)
    Verify-Installed $app $stage
    $parent=Split-Path $versionRoot;Reject-Links $parent;New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Move-Item -LiteralPath $stage -Destination $versionRoot;$stage=$null;$receipt.installed+= $app.name
   }
   Save-Json $receipt $receiptPath
  }
  $docs=Join-Path $target ('Documentation\'+$script:Manifest.bundleVersion);New-Item -ItemType Directory -Path $docs -Force | Out-Null
  foreach($name in @('Notices','README.txt','APPS.txt','BUNDLE-LICENSE.txt')){Copy-Item -LiteralPath (Join-Path $script:BundleRoot $name) -Destination $docs -Recurse -Force}
  $launchers=Join-Path $target 'Launchers';Reject-Links $launchers;New-Item -ItemType Directory -Path $launchers -Force | Out-Null
  foreach($app in $script:Manifest.apps){
   $exe=Inside (Join-Path $target ('Apps\'+$app.name+'\'+$app.version+'\'+$app.gui)) $target
   $argsForApp=''
   if($app.name -eq 'LightCraft'){$library=Join-Path $target 'Libraries\LightCraft';New-Item -ItemType Directory -Path $library -Force | Out-Null;$argsForApp='--library "'+$library+'"'}
   $link=Join-Path $launchers ($app.name+'.lnk');Make-Link $link $exe $argsForApp;$receipt.shortcuts+= $link
  }
  if($externalShortcuts){
   $programs=[Environment]::GetFolderPath('Programs');$desktopFolder=[Environment]::GetFolderPath('Desktop')
   if($ShortcutRoot){Reject-Links $ShortcutRoot;$programs=Join-Path $ShortcutRoot 'Start Menu';$desktopFolder=Join-Path $ShortcutRoot 'Desktop';New-Item -ItemType Directory -Path $programs,$desktopFolder -Force | Out-Null}
   $shell=New-Object -ComObject WScript.Shell;$menu=$null;$desktop=$null
   for($number=1;$number -le 99;$number++){
    $group='Craft Suite';if($number -gt 1){$group+=' ('+$number+')'}
    $candidate=Join-Path $programs $group;$desktopCandidate=Join-Path $desktopFolder ($group+'.lnk');$owner=Join-Path $candidate 'installation-location.txt'
    $owned=(Test-Path -LiteralPath $owner) -and ((Get-Content -LiteralPath $owner -Raw).Trim() -eq $target)
    $unused=-not(Test-Path -LiteralPath $candidate) -or (@(Get-ChildItem -LiteralPath $candidate -Force).Count -eq 0)
    $desktopFree=-not(Test-Path -LiteralPath $desktopCandidate) -or $shell.CreateShortcut($desktopCandidate).TargetPath -eq $launchers
    if(($owned -or $unused) -and $desktopFree){$menu=$candidate;$desktop=$desktopCandidate;break}
   }
   if(-not $menu){throw 'No free shortcut group name; local Launchers remain usable.'}
   Reject-Links $menu;New-Item -ItemType Directory -Path $menu -Force | Out-Null;$target | Set-Content -LiteralPath (Join-Path $menu 'installation-location.txt') -Encoding UTF8
   foreach($app in $script:Manifest.apps){Copy-Item -LiteralPath (Join-Path $launchers ($app.name+'.lnk')) -Destination $menu -Force}
   $l=$shell.CreateShortcut($desktop);$l.TargetPath=$launchers;$l.Description='Open your installed Craft apps';$l.Save();$receipt.shortcuts+= $desktop;$receipt.shortcuts+= $menu
  }
  $receipt.status='complete';Save-Json $receipt $receiptPath;Status 'All 12 apps are installed. Open the Launchers folder to start creating.' 100
  return [pscustomobject]$receipt
 }catch{
  $receipt.status='incomplete';$receipt.errors+= $_.Exception.Message;Save-Json $receipt $receiptPath
  throw
 }finally{
  if($stage -and (Test-Path -LiteralPath $stage)){
   $safe=Inside $stage $target
   if([IO.Path]::GetFileName($safe) -notlike '.craft-install-*'){throw 'Refusing unsafe staging cleanup'}
   Reject-Links $safe;Remove-Item -LiteralPath $safe -Recurse -Force
  }
 }
}

if($VerifyOnly){Verify-Payloads;[pscustomobject]@{status='verified';apps=$script:Manifest.apps.Count}|ConvertTo-Json;exit 0}
if($Destination){$result=Install-Suite $Destination (-not $NoShortcuts);$result|ConvertTo-Json -Depth 15;exit 0}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='Craft Suite Setup';$form.StartPosition='CenterScreen';$form.Font=[Drawing.Font]::new('Segoe UI',10);$form.BackColor=[Drawing.Color]::FromArgb(245,247,251)
$form.ClientSize=[Drawing.Size]::new(780,[Math]::Min(680,[Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height-100));$form.MinimumSize=[Drawing.Size]::new(680,540);$form.MaximizeBox=$false
function Text-Control($parent,$text,$x,$y,$width,$height,$points=10,$bold=$false,$colour='#243249'){
 $c=New-Object Windows.Forms.Label;$c.Text=$text;$c.Location=[Drawing.Point]::new($x,$y);$c.Size=[Drawing.Size]::new($width,$height);$style=[Drawing.FontStyle]::Regular;if($bold){$style=[Drawing.FontStyle]::Bold};$c.Font=[Drawing.Font]::new('Segoe UI',$points,$style);$c.ForeColor=[Drawing.ColorTranslator]::FromHtml($colour);$parent.Controls.Add($c);return $c
}
$header=New-Object Windows.Forms.Panel;$header.Width=780;$header.Dock='Top';$header.Height=130;$header.BackColor=[Drawing.ColorTranslator]::FromHtml('#182b4b')
[void](Text-Control $header 'CRAFT SUITE' 24 16 680 20 10 $true '#aac9ff')
[void](Text-Control $header 'Your creative toolkit.' 24 40 680 46 27 $true '#ffffff')
[void](Text-Control $header 'Twelve apps. One simple, offline installation.' 26 93 680 25 11 $false '#d5e2f5')
$footer=New-Object Windows.Forms.Panel;$footer.Width=780;$footer.Dock='Bottom';$footer.Height=98;$footer.BackColor=[Drawing.Color]::White
$body=New-Object Windows.Forms.Panel;$body.Width=780;$body.Dock='Fill';$body.AutoScroll=$true
$choices=New-Object Windows.Forms.Panel;$choices.Width=780;$choices.Height=110;$choices.Dock='Bottom';$choices.BackColor=$form.BackColor
$content=New-Object Windows.Forms.Panel;$content.Location=[Drawing.Point]::new(24,16);$content.Size=[Drawing.Size]::new(732,296);$content.Anchor='Top,Left,Right';$body.Controls.Add($content)
[void](Text-Control $content 'Everything you need to get started' 0 0 680 28 13 $true)
$cards=New-Object Windows.Forms.TableLayoutPanel;$cards.Location=[Drawing.Point]::new(-5,34);$cards.Size=[Drawing.Size]::new(742,258);$cards.Anchor='Top,Left,Right';$cards.ColumnCount=3;$cards.RowCount=4
for($i=0;$i -lt 3;$i++){[void]$cards.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,33.3333))}
for($i=0;$i -lt 4;$i++){[void]$cards.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,25))}
$descriptions=@{FilmCraft='Video editing';EffectCraft='Motion graphics';SoundCraft='Audio editing and mixing';PhotoCraft='Image editing';LightCraft='Photo organisation';VectorCraft='Vector illustration';DesignCraft='Page layouts';CADCraft='CAD drawing and drafting';PdfCraft='PDF viewing and editing';WordCraft='Word processing';GridCraft='Spreadsheets';DeckCraft='Presentations'}
$order=@('FilmCraft','EffectCraft','SoundCraft','PhotoCraft','LightCraft','VectorCraft','DesignCraft','CADCraft','PdfCraft','WordCraft','GridCraft','DeckCraft')
$n=0
foreach($name in $order){
 $card=New-Object Windows.Forms.Panel;$card.Dock='Fill';$card.Margin=[Windows.Forms.Padding]::new(5);$card.BackColor=[Drawing.Color]::White
 $title=Text-Control $card $name 12 7 208 21 10 $true;$title.Anchor='Top,Left,Right'
 $description=Text-Control $card $descriptions[$name] 12 29 208 19 9 $false '#607087';$description.Anchor='Top,Left,Right'
 $cards.Controls.Add($card,($n%3),[Math]::Floor($n/3));$n++
}
$content.Controls.Add($cards)
[void](Text-Control $choices 'Where would you like to install them?' 24 8 650 24 10 $true)
$location=New-Object Windows.Forms.TextBox;$location.Location=[Drawing.Point]::new(24,37);$location.Size=[Drawing.Size]::new(616,27);$location.Anchor='Top,Left,Right'
$location.Text=Join-Path $env:LOCALAPPDATA 'Craft Suite';if(Test-Path -LiteralPath 'D:\'){$location.Text='D:\Craft Suite'};$choices.Controls.Add($location)
$browse=New-Object Windows.Forms.Button;$browse.Text='Choose folder';$browse.Location=[Drawing.Point]::new(652,34);$browse.Size=[Drawing.Size]::new(104,33);$browse.Anchor='Top,Right';$browse.FlatStyle='Flat';$browse.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#ccd6e4');$browse.BackColor=[Drawing.Color]::White;$choices.Controls.Add($browse)
$browse.Add_Click({$dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Choose a parent folder. Craft Suite will be added inside it.';$dialog.ShowNewFolderButton=$true;if($dialog.ShowDialog() -eq 'OK'){$location.Text=Join-Path $dialog.SelectedPath 'Craft Suite'};$dialog.Dispose()})
$shortcuts=New-Object Windows.Forms.CheckBox;$shortcuts.Text='Add easy-to-find Desktop and Start Menu shortcuts';$shortcuts.Checked=$true;$shortcuts.Location=[Drawing.Point]::new(24,78);$shortcuts.Size=[Drawing.Size]::new(650,26);$choices.Controls.Add($shortcuts)
$progress=New-Object Windows.Forms.ProgressBar;$progress.Location=[Drawing.Point]::new(24,11);$progress.Size=[Drawing.Size]::new(732,6);$progress.Anchor='Top,Left,Right';$footer.Controls.Add($progress)
$status=Text-Control $footer 'Ready when you are.' 24 28 494 23 10 $true
$status.Anchor='Top,Left,Right'
$detail=Text-Control $footer 'Windows 10/11 x64. About 1.4 GB installed. No downloads.' 24 53 494 23 9 $false '#607087';$detail.Anchor='Top,Left,Right'
$install=New-Object Windows.Forms.Button;$install.Text='Install all 12 apps';$install.Location=[Drawing.Point]::new(540,29);$install.Size=[Drawing.Size]::new(216,46);$install.Anchor='Top,Right';$install.BackColor=[Drawing.ColorTranslator]::FromHtml('#244f9c');$install.ForeColor=[Drawing.Color]::White;$install.Font=[Drawing.Font]::new('Segoe UI',11,[Drawing.FontStyle]::Bold);$install.FlatStyle='Flat';$install.FlatAppearance.BorderSize=0;$footer.Controls.Add($install)
$form.Controls.Add($body);$form.Controls.Add($choices);$form.Controls.Add($footer);$form.Controls.Add($header);$body.BringToFront()
$script:Busy=$false;$script:InstalledTarget=$null;$script:UiError=$null
$form.Add_FormClosing({param($sender,$eventArgs)if($script:Busy){$eventArgs.Cancel=$true}})
$script:ProgressCallback={param($message,$percent)$status.Text=$message;$progress.Value=$percent;[Windows.Forms.Application]::DoEvents()}
$install.Add_Click({
 if($script:InstalledTarget){Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+(Join-Path $script:InstalledTarget 'Launchers')+'"');$form.Close();return}
 $script:Busy=$true;$install.Enabled=$false;$location.Enabled=$false;$browse.Enabled=$false;$shortcuts.Enabled=$false;$detail.Text='Please keep this window open while your apps are installed.'
 try{$result=Install-Suite $location.Text $shortcuts.Checked;$script:InstalledTarget=$result.destination;$install.Text='Open your apps';$status.Text="You're ready to create.";$detail.Text='All 12 apps are installed. You can remove the extracted setup folder.'}
 catch{$script:UiError=$_.Exception.Message;$status.Text='Setup could not finish.';$detail.Text='Your existing files have been preserved.';if(-not $GuiTestDestination){[void][Windows.Forms.MessageBox]::Show($form,$script:UiError,'Setup needs your attention','OK','Information')};$location.Enabled=$true;$browse.Enabled=$true;$shortcuts.Enabled=$true}
 finally{$script:Busy=$false;$install.Enabled=$true}
})
function Snapshot-Form([string]$path){$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose()}
if($PreviewImage -or $GuiTestDestination){
 if($PreviewWidth -gt 0){$form.Width=$PreviewWidth;$form.Height=580}
 $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=[Drawing.Point]::new(-5000,-5000);$form.Show();[Windows.Forms.Application]::DoEvents()
 if($GuiTestDestination){$location.Text=$GuiTestDestination;$shortcuts.Checked=-not $NoShortcuts;$install.PerformClick();if($script:InstalledTarget -ne $GuiTestDestination -or $progress.Value -ne 100){$form.Close();throw ('GUI install failed: '+$script:UiError)}}
 if($PreviewImage){Snapshot-Form $PreviewImage}
 if($GuiTestImage){Snapshot-Form $GuiTestImage}
 $form.Close();$form.Dispose();if($GuiTestDestination){[pscustomobject]@{status='complete';buttonInvoked=$true;progress=100;destination=$script:InstalledTarget}|ConvertTo-Json};exit 0
}
[void]$form.ShowDialog();$form.Dispose()
