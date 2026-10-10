[CmdletBinding()]
param([string]$Destination,[switch]$NoShortcuts,[switch]$VerifyOnly,[string]$PreviewImage,[string]$ShortcutRoot,[string]$GuiTestDestination,[string]$GuiTestImage,[int]$PreviewWidth=0,[string]$Apps,[string]$InspectDestination,[string]$PreferenceRoot,[string]$PreviewCategory,[string]$ActionTestRoot,[string]$PreviewAppMenu)
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
function Verify-Payloads($selected=$script:Manifest.apps) {
 if(-not [Environment]::Is64BitOperatingSystem){throw 'These apps require 64-bit Windows.'}
 $n=0
 foreach($app in $selected){
  $n++;Status ('Checking '+$app.name+'...') ([int](20*$n/$selected.Count))
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
function Make-Link([string]$path,[string]$target,[string]$argsForApp='',[string]$ownedAppRoot=''){
 Reject-Links $path
 $shell=New-Object -ComObject WScript.Shell
 if(Test-Path -LiteralPath $path){$existing=$shell.CreateShortcut($path);if($existing.TargetPath -ne $target){if(-not $ownedAppRoot){throw 'An unrelated shortcut already exists and was preserved: '+$path};[void](Inside $existing.TargetPath $ownedAppRoot)}}
 $link=$shell.CreateShortcut($path);$link.TargetPath=$target;$link.Arguments=$argsForApp;$link.WorkingDirectory=Split-Path $target;$link.IconLocation=$target+',0';$link.Description='Official unmodified '+[IO.Path]::GetFileNameWithoutExtension($target)+' release';$link.Save()
}
function Compare-AppVersion([string]$left,[string]$right){
 $pattern='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$'
 $a=[regex]::Match($left,$pattern);$b=[regex]::Match($right,$pattern)
 if(-not $a.Success -or -not $b.Success){throw 'Unrecognised version; automatic comparison is unavailable.'}
 for($i=1;$i -le 3;$i++){$n=[bigint]::Parse($a.Groups[$i].Value).CompareTo([bigint]::Parse($b.Groups[$i].Value));if($n){return $n}}
 $ap=$a.Groups[4].Value;$bp=$b.Groups[4].Value
 if(-not $ap -and -not $bp){return 0};if(-not $ap){return 1};if(-not $bp){return -1}
 $aa=$ap.Split('.');$bb=$bp.Split('.')
 for($i=0;$i -lt [Math]::Min($aa.Count,$bb.Count);$i++){
  $an=$aa[$i] -match '^[0-9]+$';$bn=$bb[$i] -match '^[0-9]+$'
  if($an -and $bn){$n=[bigint]::Parse($aa[$i]).CompareTo([bigint]::Parse($bb[$i]))}
  elseif($an){$n=-1}elseif($bn){$n=1}else{$n=[string]::CompareOrdinal($aa[$i],$bb[$i])}
  if($n){return $n}
 }
 return $aa.Count.CompareTo($bb.Count)
}
function Select-Apps([string[]]$names){
 if(-not $names -or $names.Count -eq 0){throw 'Select at least one app.'}
 $selected=@();foreach($name in $names){$app=@($script:Manifest.apps | Where-Object {$_.name -eq $name});if($app.Count -ne 1){throw ('Unknown app: '+$name)};if($selected.name -notcontains $app[0].name){$selected+= $app[0]}}
 return $selected
}
function App-State($app,[string]$target){
 $state=[ordered]@{name=$app.name;bundled=$app.version;installed=$null;status='Not installed';select=$true}
 try{
  if(-not [IO.Path]::IsPathRooted($target)){throw 'Choose an installation folder.'}
  Reject-Links $target
  $receiptPath=Join-Path $target 'suite-installation.json';$receipt=$null
  if(Test-Path -LiteralPath $receiptPath){Reject-Links $receiptPath;$receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json;if($receipt.bundleId -ne $script:Manifest.bundleId){throw 'Another installation owns this folder.'}}
  elseif((Test-Path -LiteralPath $target) -and @(Get-ChildItem -LiteralPath $target -Force).Count){throw 'Choose an empty folder or an existing Craft Suite installation.'}
  $appRoot=Join-Path $target ('Apps\'+$app.name);Reject-Links $appRoot
  $found=@();if(Test-Path -LiteralPath $appRoot){$found=@(Get-ChildItem -LiteralPath $appRoot -Directory | ForEach-Object {$_.Name})}
  $active=@($receipt.activeApps | Where-Object {$_.name -eq $app.name})
  if($active.Count -eq 1){$state.installed=$active[0].version}
  elseif($active.Count -gt 1){throw 'Conflicting installation record.'}
  else{
   # Legacy bundles recorded names only; use their owned launcher, then version folders.
   $link=Join-Path $target ('Launchers\'+$app.name+'.lnk');Reject-Links $link
   if(Test-Path -LiteralPath $link){$shell=New-Object -ComObject WScript.Shell;$old=$shell.CreateShortcut($link).TargetPath;$relative=(Inside $old $appRoot).Substring($appRoot.Length+1);$state.installed=$relative.Split('\')[0]}
   if(-not $state.installed){foreach($version in $found){if(-not $state.installed -or (Compare-AppVersion $version $state.installed) -gt 0){$state.installed=$version}}}
  }
  if($state.installed){
   if($found -notcontains $state.installed){throw 'Recorded version folder is missing.'}
   # A retained newer version also blocks accidental downgrades, even if an older launcher was selected.
   $newest=$state.installed;foreach($version in $found){if((Compare-AppVersion $version $newest) -gt 0){$newest=$version}}
   if((Compare-AppVersion $newest $app.version) -gt 0){$state.status='Newer than this bundle';$state.select=$false}
   elseif((Compare-AppVersion $state.installed $app.version) -eq 0){$state.status='Up to date';$state.select=$false}
   else{$state.status='Update available'}
  }
 }catch{$state.status='Needs attention';$state.select=$false;$state['detail']=$_.Exception.Message}
 return [pscustomobject]$state
}

function Install-Suite([string]$chosen,[bool]$externalShortcuts,[string[]]$names=@($script:Manifest.apps.name)){
 $selected=@(Select-Apps $names)
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
 foreach($app in $selected){$state=App-State $app $target;if($state.status -eq 'Newer than this bundle'){throw ('Downgrade refused for '+$app.name+'. Use a newer suite bundle; existing versions were preserved.')};if($state.status -eq 'Needs attention'){throw ($app.name+': '+$state.detail)}}
 Verify-Payloads $selected
 # Check existing versions before any mutations, preserving modified files and additional user data.
 foreach($app in $selected){
  $versionRoot=Inside (Join-Path $target ('Apps\'+$app.name+'\'+$app.version)) $target
  if(Test-Path -LiteralPath $versionRoot){Reject-Links $versionRoot;Verify-Installed $app $versionRoot}
 }
 $drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($target))
 $missing=@($selected | Where-Object {-not(Test-Path -LiteralPath (Join-Path $target ('Apps\'+$_.name+'\'+$_.version)))});$total=($missing | Measure-Object installedBytes -Sum).Sum;$largest=($missing | Measure-Object installedBytes -Maximum).Maximum;$needed=[long]$total+[long]$largest+268435456
 if($drive.AvailableFreeSpace -lt $needed){throw 'Not enough free space on the chosen drive. Allow at least 2 GB for installation.'}
 $activeApps=@();foreach($app in $script:Manifest.apps){$state=App-State $app $target;if($state.installed -and $state.status -ne 'Needs attention'){$activeApps+= [pscustomobject]@{name=$app.name;version=$state.installed}}}
 foreach($app in $selected){$link=Join-Path $target ('Launchers\'+$app.name+'.lnk');Reject-Links $link;if(Test-Path -LiteralPath $link){$shell=New-Object -ComObject WScript.Shell;[void](Inside $shell.CreateShortcut($link).TargetPath (Join-Path $target ('Apps\'+$app.name)))}}
 New-Item -ItemType Directory -Path $target -Force | Out-Null
 $receipt=[ordered]@{bundleId=$script:Manifest.bundleId;bundleVersion=$script:Manifest.bundleVersion;destination=$target;schemaVersion=2;selected=@($selected.name);activeApps=@($activeApps);status='installing';installed=@();reused=@();shortcuts=@();errors=@()}
 Save-Json $receipt $receiptPath
 $stage=$null
 try{
  $n=0
  foreach($app in $selected){
   $n++;Status ('Installing '+$app.name+' '+$app.version+'...') (20+[int](65*$n/$selected.Count))
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
  $docs=Join-Path $target ('Documentation\'+$script:Manifest.bundleVersion);Reject-Links $docs;New-Item -ItemType Directory -Path $docs -Force | Out-Null
  foreach($name in @('Notices','README.txt','APPS.txt','BUNDLE-LICENSE.txt')){Copy-Item -LiteralPath (Join-Path $script:BundleRoot $name) -Destination $docs -Recurse -Force}
  $launchers=Join-Path $target 'Launchers';Reject-Links $launchers;New-Item -ItemType Directory -Path $launchers -Force | Out-Null
  foreach($app in $selected){
   $exe=Inside (Join-Path $target ('Apps\'+$app.name+'\'+$app.version+'\'+$app.gui)) $target
   $argsForApp=''
   if($app.name -eq 'LightCraft'){$library=Join-Path $target 'Libraries\LightCraft';Reject-Links $library;New-Item -ItemType Directory -Path $library -Force | Out-Null;$argsForApp='--library "'+$library+'"'}
   $link=Join-Path $launchers ($app.name+'.lnk');Make-Link $link $exe $argsForApp (Join-Path $target ('Apps\'+$app.name));$receipt.activeApps=@($receipt.activeApps | Where-Object {$_.name -ne $app.name})+@([pscustomobject]@{name=$app.name;version=$app.version});$receipt.shortcuts+= $link
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
   foreach($app in $selected){Copy-Item -LiteralPath (Join-Path $launchers ($app.name+'.lnk')) -Destination $menu -Force}
   $l=$shell.CreateShortcut($desktop);$l.TargetPath=$launchers;$l.Description='Open your installed Craft apps';$l.Save();$receipt.shortcuts+= $desktop;$receipt.shortcuts+= $menu
  }
  $receipt.status='complete';Save-Json $receipt $receiptPath;Status ('Your '+$selected.Count+' selected apps are ready. Other apps and older versions were preserved.') 100
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

if($InspectDestination){@($script:Manifest.apps | ForEach-Object {App-State $_ $InspectDestination}) | ConvertTo-Json -Depth 8;exit 0}
$requested=@($script:Manifest.apps.name);if($Apps){$requested=@($Apps.Split(',') | ForEach-Object {$_.Trim()});[void](Select-Apps $requested)}
if($VerifyOnly){Verify-Payloads (Select-Apps $requested);[pscustomobject]@{status='verified';apps=$script:Manifest.apps.Count}|ConvertTo-Json;exit 0}
if($Destination){$result=Install-Suite $Destination (-not $NoShortcuts) $requested;$result|ConvertTo-Json -Depth 15;exit 0}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Add-Type -TypeDefinition @'
using System; using System.Drawing; using System.Drawing.Drawing2D; using System.Windows.Forms;
public class CraftSuiteCard : Panel {
 public bool Selected=false;
 public CraftSuiteCard(){DoubleBuffered=true;BackColor=Color.FromArgb(243,240,235);}
 protected override void OnPaint(PaintEventArgs e){
  base.OnPaint(e);e.Graphics.SmoothingMode=SmoothingMode.AntiAlias;
  RectangleF r=new RectangleF(1,1,Width-3,Height-3);float d=16;
  using(GraphicsPath p=new GraphicsPath()){
   p.AddArc(r.Left,r.Top,d,d,180,90);p.AddArc(r.Right-d,r.Top,d,d,270,90);
   p.AddArc(r.Right-d,r.Bottom-d,d,d,0,90);p.AddArc(r.Left,r.Bottom-d,d,d,90,90);p.CloseFigure();
   using(Brush b=new SolidBrush(Selected?Color.FromArgb(252,233,238):Color.White))e.Graphics.FillPath(b,p);
   using(Pen pen=new Pen(Selected?Color.FromArgb(227,19,59):Color.FromArgb(213,208,202),Selected?1.5f:1f))e.Graphics.DrawPath(pen,p);
  }
 }
}
'@ -ReferencedAssemblies System.Drawing,System.Windows.Forms
$form=New-Object Windows.Forms.Form
$form.Text='Craft Suite Setup';$form.StartPosition='CenterScreen';$form.Font=[Drawing.Font]::new('Segoe UI',10);$form.BackColor=[Drawing.ColorTranslator]::FromHtml('#f3f0eb')
$form.ClientSize=[Drawing.Size]::new(940,[Math]::Min(850,[Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Height-100));$form.MinimumSize=[Drawing.Size]::new(650,640);$form.MaximizeBox=$true
function Text-Control($parent,$text,$x,$y,$width,$height,$points=10,$bold=$false,$colour='#121214'){
 $c=New-Object Windows.Forms.Label;$c.UseMnemonic=$false;$c.Text=$text;$c.BackColor=[Drawing.Color]::Transparent;$c.Location=[Drawing.Point]::new($x,$y);$c.Size=[Drawing.Size]::new($width,$height);$style=[Drawing.FontStyle]::Regular;if($bold){$style=[Drawing.FontStyle]::Bold};$c.Font=[Drawing.Font]::new('Segoe UI',$points,$style);$c.ForeColor=[Drawing.ColorTranslator]::FromHtml($colour);$parent.Controls.Add($c);return $c
}
function Plain-Button($parent,$text,$x,$y,$width){
 $b=New-Object Windows.Forms.Button;$b.UseMnemonic=$false;$b.Text=$text;$b.Location=[Drawing.Point]::new($x,$y);$b.Size=[Drawing.Size]::new($width,30);$b.FlatStyle='Flat';$b.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#d5d0ca');$b.BackColor=[Drawing.Color]::White;$b.Font=[Drawing.Font]::new('Segoe UI',9);$parent.Controls.Add($b);return $b
}
$header=New-Object Windows.Forms.Panel;$header.Width=940;$header.Dock='Top';$header.Height=112;$header.BackColor=[Drawing.ColorTranslator]::FromHtml('#121214')
[void](Text-Control $header 'CRAFT SUITE' 28 17 650 20 9 $true '#ff8aa3')
[void](Text-Control $header 'Make room for your next idea.' 26 39 840 39 25 $true '#ffffff')
[void](Text-Control $header 'Choose your tools. Install them once. Add more whenever you need them.' 28 82 860 22 10 $false '#e7e2dc')
$toolbar=New-Object Windows.Forms.Panel;$toolbar.Width=940;$toolbar.Dock='Top';$toolbar.Height=94;$toolbar.BackColor=$form.BackColor
[void](Text-Control $toolbar 'Your apps' 28 12 280 29 16 $true)
$selectAll=Plain-Button $toolbar 'Select all apps' 668 12 112;$selectAll.Anchor='Top,Right'
$selectNone=Plain-Button $toolbar 'Clear selection' 792 12 120;$selectNone.Anchor='Top,Right'
$script:Category='All apps';$script:CategoryButtons=@{}
$categories=@('All apps','Video & audio','Photo & design','Documents & CAD');$cx=28
foreach($categoryName in $categories){$button=Plain-Button $toolbar $categoryName $cx 54 132;$button.Tag=$categoryName;$script:CategoryButtons[$categoryName]=$button;$button.Add_Click({$script:Category=$this.Tag;Layout-AppCards});$cx+=142}
$footer=New-Object Windows.Forms.Panel;$footer.Width=940;$footer.Dock='Bottom';$footer.Height=96;$footer.BackColor=[Drawing.Color]::White
$choices=New-Object Windows.Forms.Panel;$choices.Width=940;$choices.Dock='Bottom';$choices.Height=104;$choices.BackColor=[Drawing.Color]::White
$body=New-Object Windows.Forms.Panel;$body.Width=940;$body.Dock='Fill';$body.AutoScroll=$true
$content=New-Object Windows.Forms.Panel;$content.Location=[Drawing.Point]::new(22,4);$content.Size=[Drawing.Size]::new(896,530);$content.Anchor='Top,Left,Right';$body.Controls.Add($content)
$cards=New-Object Windows.Forms.FlowLayoutPanel;$cards.Location=[Drawing.Point]::new(0,0);$cards.Size=[Drawing.Size]::new(896,520);$cards.WrapContents=$true;$cards.FlowDirection='LeftToRight';$content.Controls.Add($cards)
$descriptions=@{FilmCraft='Premiere Pro-style editor';EffectCraft='After Effects-style motion';SoundCraft='Pro Tools-style audio';PhotoCraft='Photoshop-style editor';LightCraft='Lightroom-style library';VectorCraft='Illustrator-style drawing';DesignCraft='InDesign-style layouts';CADCraft='AutoCAD-style drafting';PdfCraft='Acrobat-style PDF tools';WordCraft='Word-style documents';GridCraft='Excel-style spreadsheets';DeckCraft='PowerPoint-style slides'}
$order=@('FilmCraft','EffectCraft','SoundCraft','PhotoCraft','LightCraft','VectorCraft','DesignCraft','CADCraft','PdfCraft','WordCraft','GridCraft','DeckCraft')
$script:Groups=@{};foreach($name in $order){$script:Groups[$name]='Documents & CAD'};foreach($name in @('FilmCraft','EffectCraft','SoundCraft')){$script:Groups[$name]='Video & audio'};foreach($name in @('PhotoCraft','LightCraft','VectorCraft','DesignCraft')){$script:Groups[$name]='Photo & design'}
$script:AppTips=New-Object Windows.Forms.ToolTip;$script:AppChecks=@{};$script:AppLabels=@{};$script:AppStates=@{};$script:AppButtons=@{};$script:AppMenus=@{};$script:AppCopies=@{};$script:CardViews=@{};$script:Refreshing=$false;$script:LayoutBusy=$false
foreach($name in $order){
 $card=New-Object CraftSuiteCard;$card.Size=[Drawing.Size]::new(286,168);$card.Margin=[Windows.Forms.Padding]::new(6);$card.Selected=$true;$script:CardViews[$name]=$card
 $icon=New-Object Windows.Forms.PictureBox;$icon.Location=[Drawing.Point]::new(18,19);$icon.Size=[Drawing.Size]::new(32,32);$icon.BackColor=[Drawing.Color]::Transparent
 $iconFile=Join-Path $script:BundleRoot ('AppIcons\'+$name+'.png');if(Test-Path -LiteralPath $iconFile){$icon.Image=[Drawing.Image]::FromFile($iconFile)};$card.Controls.Add($icon)
 $title=Text-Control $card $name 62 15 206 26 12 $true;$title.Anchor='Top,Left,Right'
 $description=Text-Control $card $descriptions[$name] 62 41 206 21 9 $false '#625e59';$description.Anchor='Top,Left,Right'
 $group=Text-Control $card $script:Groups[$name] 18 73 248 20 8 $false '#726c66';$group.Anchor='Top,Left,Right'
 $stateLabel=Text-Control $card '' 18 100 148 22 9 $false '#625e59';$stateLabel.Anchor='Top,Left,Right';$script:AppLabels[$name]=$stateLabel
 $check=New-Object Windows.Forms.CheckBox;$check.Text='Include';$check.Checked=$true;$check.Location=[Drawing.Point]::new(192,97);$check.Size=[Drawing.Size]::new(76,26);$check.BackColor=[Drawing.Color]::Transparent;$check.Anchor='Top,Right';$card.Controls.Add($check);$script:AppChecks[$name]=$check
 $check.Add_CheckedChanged({if(-not $script:Refreshing){if(-not $script:Busy){$script:InstalledTarget=$null;$install.Text='Install / update selected'};Update-SelectionSummary}})
 $toggle={if($check.Enabled -and -not $script:Busy){$check.Checked=-not $check.Checked}}.GetNewClosure();$card.Add_Click($toggle);$title.Add_Click($toggle);$icon.Add_Click($toggle)
 $main=Plain-Button $card 'Install' 150 128 82;$main.Anchor='Top,Right';$main.Tag=$name;$main.ForeColor=[Drawing.ColorTranslator]::FromHtml('#b00e2d');$script:AppButtons[$name]=$main
 $main.Add_Click({Invoke-CardAction $this.Tag})
 $more=Plain-Button $card ([char]0x22EF).ToString() 238 128 30;$more.Anchor='Top,Right';$more.Tag=$name;$more.AccessibleName='More options for '+$name;$script:AppMenus[$name]=$more
 $script:AppTips.SetToolTip($more,'Open, show folder or install another copy')
 $more.Add_Click({Show-AppMenu $this.Tag $this})
 $cards.Controls.Add($card)
}
function Sync-CardStyles {foreach($name in $order){$script:CardViews[$name].Selected=$script:AppChecks[$name].Checked;$script:CardViews[$name].Invalidate()}}
function Layout-AppCards {
 if($script:LayoutBusy){return};$script:LayoutBusy=$true
 try{
  $width=[Math]::Max(540,$body.ClientSize.Width-44);$cols=2;if($width -ge 810){$cols=3}
  $cardWidth=[int][Math]::Floor($width/$cols)-12;$visible=0;$cards.SuspendLayout()
  foreach($name in $order){$card=$script:CardViews[$name];$showCard=($script:Category -eq 'All apps' -or $script:Groups[$name] -eq $script:Category);$card.Visible=$showCard;$card.Size=[Drawing.Size]::new($cardWidth,168);if($showCard){$visible++}}
  $cards.Width=$width;$content.Width=$width;$height=[int][Math]::Ceiling($visible/$cols)*180;$cards.Height=[Math]::Max(180,$height);$content.Height=$cards.Height+10;$cards.ResumeLayout()
  foreach($categoryName in $categories){$b=$script:CategoryButtons[$categoryName];$b.BackColor=[Drawing.Color]::White;$b.ForeColor=[Drawing.ColorTranslator]::FromHtml('#625e59');if($categoryName -eq $script:Category){$b.BackColor=[Drawing.ColorTranslator]::FromHtml('#fce9ee');$b.ForeColor=[Drawing.ColorTranslator]::FromHtml('#b00e2d')}}
 }finally{$script:LayoutBusy=$false}
}
$body.Add_SizeChanged({Layout-AppCards})
[void](Text-Control $choices 'Installation folder' 28 8 600 22 10 $true)
$location=New-Object Windows.Forms.TextBox;$location.Location=[Drawing.Point]::new(28,35);$location.Size=[Drawing.Size]::new(754,27);$location.Anchor='Top,Left,Right';$location.Text=Join-Path $env:LOCALAPPDATA 'Craft Suite';if(Test-Path -LiteralPath 'D:\'){$location.Text='D:\Craft Suite'};$choices.Controls.Add($location)
$browse=Plain-Button $choices 'Choose folder' 796 33 116;$browse.Anchor='Top,Right'
$browse.Add_Click({$dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Choose a parent folder. Craft Suite will be added inside it.';$dialog.ShowNewFolderButton=$true;if($dialog.ShowDialog() -eq 'OK'){$location.Text=Join-Path $dialog.SelectedPath 'Craft Suite'};$dialog.Dispose()})
$shortcuts=New-Object Windows.Forms.CheckBox;$shortcuts.Text='Add Desktop and Start Menu shortcuts';$shortcuts.Checked=$true;$shortcuts.Location=[Drawing.Point]::new(28,70);$shortcuts.Size=[Drawing.Size]::new(600,25);$choices.Controls.Add($shortcuts)
$progress=New-Object Windows.Forms.ProgressBar;$progress.Location=[Drawing.Point]::new(28,8);$progress.Size=[Drawing.Size]::new(884,5);$progress.Anchor='Top,Left,Right';$footer.Controls.Add($progress)
$status=Text-Control $footer 'Choose your tools.' 28 24 636 26 11 $true;$status.Anchor='Top,Left,Right'
$detail=Text-Control $footer '' 28 53 636 23 9 $false '#625e59';$detail.Anchor='Top,Left,Right'
$install=Plain-Button $footer 'Install / update selected' 690 26 222;$install.Height=46;$install.Anchor='Top,Right';$install.BackColor=[Drawing.ColorTranslator]::FromHtml('#e3133b');$install.ForeColor=[Drawing.Color]::White;$install.Font=[Drawing.Font]::new('Segoe UI',10,[Drawing.FontStyle]::Bold);$install.FlatAppearance.BorderSize=0
$form.Controls.Add($body);$form.Controls.Add($choices);$form.Controls.Add($footer);$form.Controls.Add($toolbar);$form.Controls.Add($header);$body.BringToFront()

$script:Busy=$false;$script:InstalledTarget=$null;$script:UiError=$null
$form.Add_FormClosing({param($sender,$eventArgs)if($script:Busy){$eventArgs.Cancel=$true}})
$script:ProgressCallback={param($message,$percent)$status.Text=$message;$progress.Value=$percent;[Windows.Forms.Application]::DoEvents()}
$install.Add_Click({
 if($script:InstalledTarget){Start-Process -FilePath 'explorer.exe' -ArgumentList ('"'+(Join-Path $script:InstalledTarget 'Launchers')+'"');$form.Close();return}
 $script:Busy=$true;$install.Enabled=$false;$cards.Enabled=$false;$selectAll.Enabled=$false;$selectNone.Enabled=$false;$toolbar.Enabled=$false;$location.Enabled=$false;$browse.Enabled=$false;$shortcuts.Enabled=$false;$detail.Text='Please keep this window open while your apps are installed.'
 try{$names=@($script:AppChecks.Keys | Where-Object {$script:AppChecks[$_].Checked});$result=Install-Suite $location.Text $shortcuts.Checked $names;$script:InstalledTarget=$result.destination;Remember-Copy $result.destination;$install.Text='Open your apps';$status.Text="You're ready to create.";$noun='apps';if($result.selected.Count -eq 1){$noun='app'};$detail.Text=($result.selected.Count.ToString()+' '+$noun+' ready. Other apps were kept.');Refresh-AppCards $false}
 catch{$script:UiError=$_.Exception.Message;$status.Text='Setup could not finish.';$detail.Text='Your existing files have been preserved.';if(-not $GuiTestDestination){[void][Windows.Forms.MessageBox]::Show($form,$script:UiError,'Setup needs your attention','OK','Information')};$location.Enabled=$true;$browse.Enabled=$true;$shortcuts.Enabled=$true}
 finally{$script:Busy=$false;$install.Enabled=$true;$cards.Enabled=$true;$selectAll.Enabled=$true;$selectNone.Enabled=$true;$toolbar.Enabled=$true}
})
function Update-SelectionSummary {
 if($script:Busy -or $script:InstalledTarget){return}
 Sync-CardStyles
 $names=@($script:AppChecks.Keys | Where-Object {$script:AppChecks[$_].Checked})
 $bytes=0;foreach($app in $script:Manifest.apps){if($names -contains $app.name){$bytes+=$app.installedBytes}}
 $detail.Text=('{0} selected across all apps - approx. {1:N0} MB.' -f $names.Count,($bytes/1MB))
 $install.Enabled=($names.Count -gt 0);$status.Text="Choose the apps you'd like to install or update.";if($names.Count -eq 0){$status.Text='Choose an app to continue.'}
}

$savedLocation=Join-Path $env:LOCALAPPDATA 'CraftSuiteSetup\last-installation.json';if($PreferenceRoot){$savedLocation=Join-Path $PreferenceRoot 'last-installation.json'}
$script:RememberEnabled=($PreferenceRoot -or (-not $GuiTestDestination -and -not $ShortcutRoot -and -not $PreviewImage))
$script:KnownDestinations=@();$script:LastUsed=@{}
if($script:RememberEnabled -and (Test-Path -LiteralPath $savedLocation)){
 try{Reject-Links $savedLocation;$saved=Get-Content -LiteralPath $savedLocation -Raw | ConvertFrom-Json
  $script:KnownDestinations=@(@($saved.destination)+@($saved.destinations) | Where-Object {$_} | Select-Object -Unique)
  foreach($entry in $saved.lastUsed){$script:LastUsed[$entry.name]=$entry.destination}
  if($saved.destination -and (Test-Path -LiteralPath (Join-Path $saved.destination 'suite-installation.json'))){$location.Text=$saved.destination}
 }catch{}
}
function Remember-Copy([string]$target,[string]$name=''){
 $script:KnownDestinations=@($script:KnownDestinations+@($target) | Select-Object -Unique)
 if($name){$script:LastUsed[$name]=$target}
 if($script:RememberEnabled){
  $folder=Split-Path $savedLocation;Reject-Links $folder;New-Item -ItemType Directory -Path $folder -Force | Out-Null
  $used=@();foreach($key in $script:LastUsed.Keys){$used+=@{name=$key;destination=$script:LastUsed[$key]}}
  Save-Json @{destination=$location.Text;destinations=$script:KnownDestinations;lastUsed=$used} $savedLocation
 }
}
function Resolve-AppLaunch($app,[string]$target){
 $state=App-State $app $target
 if(-not $state.installed -or $state.status -eq 'Needs attention'){throw 'This copy is missing or needs attention. Choose a valid installation folder.'}
 $root=Inside (Join-Path $target ('Apps\'+$app.name+'\'+$state.installed)) $target;Reject-Links $root
 $exe=Inside (Join-Path $root $app.gui) $root;Reject-Links $exe
 if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){throw 'The app executable is missing. Install another copy or repair this installation.'}
 # Compare current bundled executables to pinned hashes. Older copies must have an owned local launcher.
 if($state.installed -eq $app.version){$file=@($app.files | Where-Object {$_.path -eq $app.gui});if($file.Count -ne 1 -or (File-Hash $exe) -ne $file[0].sha256){throw 'The app executable differs from the release. It was preserved; choose another copy.'}}
 else{$link=Join-Path $target ('Launchers\'+$app.name+'.lnk');Reject-Links $link;if(-not(Test-Path -LiteralPath $link)){throw 'The installed launcher is missing.'};$shell=New-Object -ComObject WScript.Shell;if($shell.CreateShortcut($link).TargetPath -ne $exe){throw 'The installed launcher does not match this copy.'}}
 $argsForApp='';if($app.name -eq 'LightCraft'){$library=Join-Path $target 'Libraries\LightCraft';Reject-Links $library;$argsForApp='--library "'+$library+'"'}
 return [pscustomobject]@{exe=$exe;arguments=$argsForApp;folder=$root;destination=$target;state=$state}
}
function Get-AppCopies($app){
 $result=@();$targets=@(@($location.Text)+$script:KnownDestinations | Where-Object {$_} | Select-Object -Unique)
 foreach($target in $targets){try{$copy=Resolve-AppLaunch $app $target;$result+=$copy}catch{}}
 return @($result | Sort-Object @{Expression={if($_.destination -eq $script:LastUsed[$app.name]){0}elseif($_.destination -eq $location.Text){1}else{2}}})
}
function Action-Error($errorRecord){
 $script:UiError=$errorRecord.Exception.Message
 if($ActionTestRoot){throw $errorRecord}
 [void][Windows.Forms.MessageBox]::Show($form,$script:UiError,'App needs your attention','OK','Information')
}
function Open-AppCopy([string]$name,[string]$target){
 try{
  $app=@($script:Manifest.apps | Where-Object {$_.name -eq $name})[0];$launch=Resolve-AppLaunch $app $target
  $start=@{FilePath=$launch.exe;WorkingDirectory=$launch.folder;PassThru=$true};if($launch.arguments){$start.ArgumentList=$launch.arguments}
  if($ActionTestRoot){$start.WindowStyle='Hidden'}
  $process=Start-Process @start;Remember-Copy $target $name
  if($ActionTestRoot){$script:TestLaunched=@{exe=$launch.exe;destination=$target;id=$process.Id};Start-Sleep -Milliseconds 600;if(-not $process.HasExited){$process.CloseMainWindow() | Out-Null;if(-not $process.WaitForExit(1500)){$process.Kill()}}}
  $status.Text=$name+' opened.';Refresh-AppCards $false
 }catch{Action-Error $_}
}
function Run-AppInstall([string]$name,[string]$target,[bool]$anotherCopy=$false){
 if($script:Busy){return}
 $script:Busy=$true;$toolbar.Enabled=$false;$cards.Enabled=$false;$choices.Enabled=$false;$install.Enabled=$false
 try{
  $result=Install-Suite $target ($(if($anotherCopy){$false}else{$shortcuts.Checked})) @($name)
  Remember-Copy $result.destination $name;$script:InstalledTarget=$null;$install.Text='Install / update selected'
  $status.Text=$name+' is ready.';$detail.Text='Open it from its card. Your other apps were kept.'
 }catch{Action-Error $_}
 finally{$script:Busy=$false;$toolbar.Enabled=$true;$cards.Enabled=$true;$choices.Enabled=$true;Refresh-AppCards $false;if($target -eq $location.Text -and $script:AppStates[$name].status -eq 'Up to date'){$script:AppChecks[$name].Checked=$false}}
}
function Install-AnotherCopy([string]$name){
 try{
  $target=$script:TestCopyDestination
  if(-not $target){
   $dialog=New-Object Windows.Forms.FolderBrowserDialog;$dialog.Description='Choose a parent folder. A new, separate Craft Suite Copy folder will be created.';$dialog.ShowNewFolderButton=$true
   try{if($dialog.ShowDialog($form) -ne 'OK'){return};$parent=$dialog.SelectedPath}finally{$dialog.Dispose()}
   $number=1;$target=Join-Path $parent 'Craft Suite Copy';while(Test-Path -LiteralPath $target){$number++;$target=Join-Path $parent ('Craft Suite Copy '+$number)}
  }
  $normal=[IO.Path]::GetFullPath($target).TrimEnd('\')
  if(@($script:KnownDestinations+@($location.Text) | Where-Object {[IO.Path]::GetFullPath($_).TrimEnd('\') -eq $normal}).Count){throw 'Choose a different folder for another copy.'}
  Run-AppInstall $name $target $true
 }catch{Action-Error $_}
}
function Invoke-CardAction([string]$name){
 $copies=@($script:AppCopies[$name]);if($copies.Count){$copy=$copies[0];if($copy.state.status -eq 'Update available'){Run-AppInstall $name $copy.destination}else{Open-AppCopy $name $copy.destination}}
 else{Run-AppInstall $name $location.Text}
}
function Build-AppMenu([string]$name){
 $menu=New-Object Windows.Forms.ContextMenuStrip;$copies=@($script:AppCopies[$name])
 if($copies.Count){
  $copy=$copies[0];$target=$copy.destination
  $item=$menu.Items.Add('Open installed version');$item.Add_Click({Open-AppCopy $name $target}.GetNewClosure())
  $item=$menu.Items.Add('Show folder');$item.Add_Click({try{$launch=Resolve-AppLaunch (@($script:Manifest.apps | Where-Object {$_.name -eq $name})[0]) $target;Start-Process explorer.exe -ArgumentList ('"'+$launch.folder+'"')}catch{Action-Error $_}}.GetNewClosure())
 }
 $item=$menu.Items.Add('Install another copy...');$item.Add_Click({Install-AnotherCopy $name}.GetNewClosure())
 if($copies.Count -gt 1){
  $choose=New-Object Windows.Forms.ToolStripMenuItem('Open another copy')
  foreach($copy in $copies){$target=$copy.destination;$item=$choose.DropDownItems.Add($target);$item.Checked=($target -eq $copies[0].destination);$item.ToolTipText='Installed version: '+$copy.state.installed;$item.Add_Click({Open-AppCopy $name $target}.GetNewClosure())}
  [void]$menu.Items.Add($choose)
 }
 return $menu
}
function Show-AppMenu([string]$name,$button){if($script:Busy){return};$menu=Build-AppMenu $name;$menu.Add_Closed({$this.Dispose()});$menu.Show($button,[Drawing.Point]::new(0,$button.Height))}

function Refresh-AppCards([bool]$reset){
 $script:Refreshing=$true
 foreach($app in $script:Manifest.apps){
  $state=App-State $app $location.Text;$script:AppStates[$app.name]=$state
  $copies=@(Get-AppCopies $app);$script:AppCopies[$app.name]=$copies;$main=$script:AppButtons[$app.name];$main.Text='Install';$main.Enabled=$state.status -notin @('Needs attention','Newer than this bundle')
  if($copies.Count){$main.Enabled=$true;$main.Text='Open';if($copies[0].state.status -eq 'Update available'){$main.Text='Update'};$script:AppTips.SetToolTip($main,$copies[0].destination)}else{$script:AppTips.SetToolTip($main,'Install into '+$location.Text)}
  $friendly=@{'Not installed'='Ready to install';'Up to date'='Already installed';'Update available'='Update available';'Newer than this bundle'='Newer version installed';'Needs attention'='Check installation folder'}
  $label=$script:AppLabels[$app.name];$label.Text=$friendly[$state.status];if($copies.Count){$label.Text=$friendly[$copies[0].state.status]}
  $tip='Included version: '+$app.version;if($state.installed){$tip='Installed version: '+$state.installed+"`n"+$tip};if($state.detail){$tip=$state.detail+"`n"+$tip}
  $script:AppTips.SetToolTip($label,$tip);$script:AppTips.SetToolTip($script:AppChecks[$app.name],$tip)
  $label.ForeColor=[Drawing.ColorTranslator]::FromHtml('#625e59')
  if(($copies.Count -and $copies[0].state.status -eq 'Update available') -or (-not $copies.Count -and $state.status -eq 'Update available')){$label.ForeColor=[Drawing.ColorTranslator]::FromHtml('#95620b')}
  if(($copies.Count -and $copies[0].state.status -eq 'Up to date') -or (-not $copies.Count -and $state.status -eq 'Up to date')){$label.ForeColor=[Drawing.ColorTranslator]::FromHtml('#276545')}
  $check=$script:AppChecks[$app.name];$check.Enabled=$state.status -notin @('Newer than this bundle','Needs attention')
  if($reset){$check.Checked=$state.select}elseif(-not $check.Enabled){$check.Checked=$false}
 }
 $script:Refreshing=$false;Sync-CardStyles;Update-SelectionSummary
}
$selectAll.Add_Click({foreach($check in $script:AppChecks.Values){if($check.Enabled){$check.Checked=$true}}})
$selectNone.Add_Click({foreach($check in $script:AppChecks.Values){$check.Checked=$false}})
$locationTimer=New-Object Windows.Forms.Timer;$locationTimer.Interval=350
$location.Add_TextChanged({$locationTimer.Stop();if(-not $script:Busy){$locationTimer.Start()}})
$locationTimer.Add_Tick({$locationTimer.Stop();if(-not $script:Busy){Refresh-AppCards $true}})
Refresh-AppCards $true;Layout-AppCards

function Snapshot-Form([string]$path){$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save($path,[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose()}
if($PreviewImage -or $GuiTestDestination -or $ActionTestRoot){
 if($PreviewWidth -gt 0){$form.Width=$PreviewWidth;$form.Height=640}
 $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=[Drawing.Point]::new(-5000,-5000);$form.Show();[Windows.Forms.Application]::DoEvents()
 if($GuiTestDestination){$location.Text=$GuiTestDestination;Refresh-AppCards $true;$selectNone.PerformClick();if($install.Enabled){throw 'Empty selection must disable installation'};$selectAll.PerformClick();$selectionBefore=@($script:AppChecks.Keys | Where-Object {$script:AppChecks[$_].Checked});$script:CategoryButtons['Video & audio'].PerformClick();if(@($script:AppChecks.Keys | Where-Object {$script:AppChecks[$_].Checked}).Count -ne $selectionBefore.Count){throw 'Category filter changed selection'};$script:CategoryButtons['All apps'].PerformClick();foreach($name in $script:AppChecks.Keys){$script:AppChecks[$name].Checked=($requested -contains $name)};$shortcuts.Checked=-not $NoShortcuts;$install.PerformClick();if($script:InstalledTarget -ne $GuiTestDestination -or $progress.Value -ne 100){$form.Close();throw ('GUI install failed: '+$script:UiError)}}
if($ActionTestRoot){
 $script:TestLaunched=$null
 $grid=$script:AppButtons['GridCraft'];$location.Text=Join-Path $ActionTestRoot 'First copy';Refresh-AppCards $true
 if($grid.Text -ne 'Install'){throw 'Fresh card must offer Install'}
 $shortcuts.Checked=$false;$script:AppChecks['FilmCraft'].Checked=$false;$grid.PerformClick();if($script:AppChecks['FilmCraft'].Checked){throw 'Single-app install reset another selection'}
 if($grid.Text -ne 'Open'){throw 'Installed card must offer Open'}
 $first=$location.Text;$firstExe=(Resolve-AppLaunch (@($script:Manifest.apps | Where-Object name -eq 'GridCraft')[0]) $first).exe
 $firstHash=File-Hash $firstExe
 $grid.PerformClick();if($script:TestLaunched.destination -ne $first){throw 'Open did not launch first copy'}
 $script:TestCopyDestination=Join-Path $ActionTestRoot 'Second copy'
 $menu=Build-AppMenu 'GridCraft';@($menu.Items | Where-Object Text -eq 'Install another copy...')[0].PerformClick();$menu.Dispose()
 $copies=@($script:AppCopies['GridCraft']);if($copies.Count -ne 2 -or $copies[0].destination -ne $script:TestCopyDestination){throw 'Separate copy was not remembered'}
 if((File-Hash $firstExe) -ne $firstHash){throw 'Original copy changed'}
 $menu=Build-AppMenu 'GridCraft';$choose=@($menu.Items | Where-Object Text -eq 'Open another copy')[0];@($choose.DropDownItems | Where-Object Text -eq $first)[0].PerformClick();$menu.Dispose()
 if($script:LastUsed['GridCraft'] -ne $first){throw 'Last used copy not updated'}
 $persist=Get-Content -LiteralPath $savedLocation -Raw | ConvertFrom-Json
 if(@($persist.destinations).Count -ne 2 -or @($persist.lastUsed | Where-Object name -eq 'GridCraft')[0].destination -ne $first){throw 'Copy preferences not saved'}
 # Simulated older release: keep the same test app bytes, change only the owned version metadata/folder/launcher.
 $second=$script:TestCopyDestination;$app=@($script:Manifest.apps | Where-Object name -eq 'GridCraft')[0];$oldVersion='0.2.0';$oldRoot=Join-Path $second ('Apps\GridCraft\'+$oldVersion)
 Move-Item -LiteralPath (Join-Path $second ('Apps\GridCraft\'+$app.version)) -Destination $oldRoot
 $receiptFile=Join-Path $second 'suite-installation.json';$receipt=Get-Content -LiteralPath $receiptFile -Raw | ConvertFrom-Json
 @($receipt.activeApps | Where-Object name -eq 'GridCraft')[0].version=$oldVersion;Save-Json $receipt $receiptFile
 $oldExe=Join-Path $oldRoot $app.gui;$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut((Join-Path $second 'Launchers\GridCraft.lnk'));$link.TargetPath=$oldExe;$link.WorkingDirectory=$oldRoot;$link.Save()
 $script:LastUsed['GridCraft']=$second;Refresh-AppCards $false;if($grid.Text -ne 'Update'){throw 'Old copy must offer Update'}
 $menu=Build-AppMenu 'GridCraft';@($menu.Items | Where-Object Text -eq 'Open installed version')[0].PerformClick();$menu.Dispose()
 if($script:TestLaunched.exe -ne $oldExe){throw 'Old version menu did not open old app'}
 $grid.PerformClick();if($grid.Text -ne 'Open' -or -not(Test-Path -LiteralPath $oldExe)){throw 'Update failed or removed old copy'}
 if((File-Hash $firstExe) -ne $firstHash){throw 'Update changed unrelated copy'}
 # Check a stale remembered copy does not leave a dead Open button.
 $secondLaunch=Resolve-AppLaunch $app $second;Move-Item -LiteralPath $secondLaunch.exe -Destination ($secondLaunch.exe+'.held');Refresh-AppCards $false
 if(@($script:AppCopies['GridCraft']).Count -ne 1 -or $script:AppCopies['GridCraft'][0].destination -ne $first){throw 'Missing app did not fall back to intact copy'}
 Move-Item -LiteralPath ($secondLaunch.exe+'.held') -Destination $secondLaunch.exe;Refresh-AppCards $false
 # Existing bulk controls and category filtering remain functional.
 $script:InstalledTarget=$null;$selectNone.PerformClick();if($install.Enabled){throw 'Empty bulk selection must disable install'}
 $script:AppChecks['GridCraft'].Checked=$true;$script:CategoryButtons['Video & audio'].PerformClick();if(-not $script:AppChecks['GridCraft'].Checked){throw 'Category changed bulk selection'}
 $script:CategoryButtons['Documents & CAD'].PerformClick();Layout-AppCards
 if($PreviewAppMenu){$menu=Build-AppMenu $PreviewAppMenu;$menu.Show($script:AppMenus[$PreviewAppMenu],[Drawing.Point]::new(0,30));[Windows.Forms.Application]::DoEvents();$bitmap=[Drawing.Bitmap]::new($menu.Width,$menu.Height);$menu.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$menu.Width,$menu.Height));$bitmap.Save(($PreviewImage+'.menu.png'));$bitmap.Dispose();$menu.Dispose()}
 if($GuiTestImage){Snapshot-Form $GuiTestImage}
 $report=@{status='pass';freshInstall=$true;openActualExecutable=$true;separateCopyMenu=$true;lastUsedChoice=$true;preferencesSaved=$true;simulatedUpdate=$true;olderCopyPreserved=$true;missingCopyFallback=$true;bulkSelection=$true}
 Save-Json $report (Join-Path $ActionTestRoot 'actions-checks.json')
}

 if($PreviewCategory){$script:CategoryButtons[$PreviewCategory].PerformClick();[Windows.Forms.Application]::DoEvents()};Layout-AppCards
 if($PreviewImage){Snapshot-Form $PreviewImage}
 if($PreviewAppMenu){$menu=Build-AppMenu $PreviewAppMenu;$menu.Show($script:AppMenus[$PreviewAppMenu],[Drawing.Point]::new(0,30));[Windows.Forms.Application]::DoEvents();$bitmap=[Drawing.Bitmap]::new($menu.Width,$menu.Height);$menu.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$menu.Width,$menu.Height));$bitmap.Save(($PreviewImage+'.menu.png'));$bitmap.Dispose();$menu.Dispose()}
 if($GuiTestImage){Snapshot-Form $GuiTestImage}
 $form.Close();$form.Dispose();if($GuiTestDestination){[pscustomobject]@{status='complete';buttonInvoked=$true;progress=100;destination=$script:InstalledTarget}|ConvertTo-Json};exit 0
}
[void]$form.ShowDialog();$form.Dispose()
