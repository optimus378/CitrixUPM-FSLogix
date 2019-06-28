## User Defined Variables ## 
# Don't forget the trailing backslashes on the paths or you'll break everything. 
$usersfolderpath = "\\SERVER\users$\" ## Redirected Folders Path
$oldprofilepath = "\\SERVER\CtxProfiles\" ### Old UPM Profile Path
$newprofilepath = "\\SERVER\FSProfiles" ## New FSLogix Profile Path
$upmfolderpath = "\Win2016v6\UPM_Profile\" ## The location of the UPM Profile relative to the Profile OSVersion. 
$domain = "SAW" ## You should have to change this unless the users are in a cross-forest trust domain. 
$vhdsize = "30720" ## Maximum VHD Size (in MB) -- This is the maximum size the VHD can expand to.

#Brings up Gui Grid... Here you Select the profiles you'd like to convert out of the Grid View. Hold Ctrl to Select multiple. 
$oldprofiles = Get-ChildItem $oldprofilepath | out-gridview -OutputMode Multiple -title "Select profile(s) to convert"

#Once profiles are selected, #oldprofiles variable is updated with the selection. 

#Below filters out Users that either do not have a Users Folder(Redirected Folders) or were not selected from the Grid. 
$olduserfolders = Get-ChildItem $usersfolderpath # Get Hashtable of Users Redirected Folders
$userlist = @()  #Create empty lisdcst to put matches. 
$compare  = Compare-Object -ReferenceObject $oldprofiles -DifferenceObject $olduserfolders -includeequal | Where-Object {$_.SideIndicator -eq '=='} | Select-Object InputObject
foreach ($i in $compare){$userlist += $i.InputObject.Name}  ###

#Start Processing of each folder name 
foreach ($user in $userlist) {
    $sam = $user  ## Folder happens to be SAM names. Yay. 
    $sid = (New-Object System.Security.Principal.NTAccount("$domain\$sam")).translate([System.Security.Principal.SecurityIdentifier]).Value  ## Get Sid

    $regtext = "Windows Registry Editor Version 5.00
 
    [HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid]
    `"ProfileImagePath`"=`"C:\\Users\\$sam`"
    `"FSL_OriginalProfileImagePath`"=`"C:\\Users\\$sam`"
    `"Flags`"=dword:00000000
    `"State`"=dword:00000000
    `"ProfileLoadTimeLow`"=dword:00000000
    `"ProfileLoadTimeHigh`"=dword:00000000
    `"RefCount`"=dword:00000000
    `"RunLogonScriptSync`"=dword:00000000
    "
# Check to see if FSlogix Folder Exists. If Not Create. FSLogix creates Profile Folders as follows $sam_$sid Ex: test.sandbox_S-1-5-21-2021715626-1873605793-3952656972-27199
    $nfolder = join-path $newprofilepath ($sid+"_"+$sam) 
    if (!(test-path $nfolder)) {New-Item -Path $nfolder -ItemType directory | Out-Null}
    & icacls $nfolder /setowner "$domain\$sam" /T /C
    & icacls $nfolder /grant $domain\$sam`:`(OI`)`(CI`)F /T
    #Create a variable for VHDX Profile Name 
    $vhd = Join-Path $nfolder ("Profile_"+$sam+".vhdx") #Create Variable for Profile Container: Fslogix default VHDX profile container are named as follows: ex: Profile_test.sandbox.vhdx

# diskpart commands
    $script1 = "create vdisk file=`"$vhd`" maximum $vhdsize type=expandable" ## This creates a 30GB Dynamic VHDX -- Adjust if needed
    $script2 = "sel vdisk file=`"$vhd`"`r`nattach vdisk"
    $script3 = "sel vdisk file=`"$vhd`"`r`ncreate part prim`r`nselect part 1`r`nformat fs=ntfs quick"
    $script4 = "sel vdisk file=`"$vhd`"`r`nsel part 1`r`nassign letter=T"
    $script5 = "sel vdisk file`"$vhd`"`r`ndetach vdisk"
    $script6 = "sel vdisk file=`"$vhd`"`r`nattach vdisk readonly`"`r`ncompact vdisk"
## Check to see if a VHD already Exists. If not, it creates one using the commands 'disk part commands; above 
    if (!(test-path $vhd)) { 
        $script1 | diskpart
        $script2 | diskpart
        Start-Sleep -s 5
        $script3 | diskpart
        $script4 | diskpart
        & label T: Profile-$sam
        New-Item -Path T:\Profile -ItemType directory | Out-Null  ## Creates a temporary T: Drive and mounts the VHDX and sets the proper folder permissions 
        start-process icacls "T:\Profile /setowner SYSTEM"
        Start-Process icacls -ArgumentList "T:\Profile /inheritance:r"
        $cmd1 = "T:\Profile /grant $env:userdomain\$sam`:`(OI`)`(CI`)F"
        Start-Process icacls -ArgumentList "T:\Profile /grant SYSTEM`:`(OI`)`(CI`)F"
        Start-Process icacls -ArgumentList "T:\Profile /grant Administrators`:`(OI`)`(CI`)F"
        Start-Process icacls -ArgumentList $cmd1
        } else {  # if the vhd does exist then attach, wait 5 seconds, assign letter T:
                $script2 | diskpart
                Start-Sleep -s 5
                $script4 | diskpart
                }
 
    # copies in the UPM profile to the Profile directory on the vhd /E /Purge - this is so it will update with the latest info
    "Copying $user to $vhd"

    & robocopy $oldprofilepath$user$upmfolderpath /E /PURGE T:\Profile /XD "Citrix" /r:0
    # creates the %localappdata%\FSLogix path if it doesnt exist
    if (!(Test-Path "T:\Profile\AppData\Local\FSLogix")) {
        New-Item -Path "T:\Profile\AppData\Local\FSLogix" -ItemType directory | Out-Null
        }

    if (!(Test-Path "T:\Profile\AppData\Local\FSLogix\ProfileData.reg")) 
        {$regtext | Out-File "T:\Profile\AppData\Local\FSLogix\ProfileData.reg" -Encoding ascii}
    

    & robocopy "$usersfolderpath$user\" T:\Profile /E /r:0 /XD "Outlook Files" "Documents"
    & robocopy "$usersfolderpath$user\Documents\" T:\Profile\Documents\ /E /XD /r:0 "My Music" "My Pictures" "My Videos" "Videos" "Music" "Pictures" "Outlook Files"
    & robocopy "$usersfolderpath$user\Documents\My Music" "T:\Profile\Music" /E /r:0
    & robocopy "$usersfolderpath$user\Documents\My Pictures" "T:\Profile\Pictures" /E /r:0
    & robocopy "$usersfolderpath$user\Documents\My Videos" "T:\Profile\Videos" /E /r:0
    
    ## Load NTUSER.DAT For Modification
    reg load HKLM\$user T:\Profile\ntuser.dat 
    ## Delete Outlook Profile
    reg delete HKLM\$user\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook /f
    reg add HKLM\$user\Software\Microsoft\Office\16.0\Outlook\Profiles\Outlook
    ## Change User Shell Folders back to Default Local Paths
  
    reg delete "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{35286A68-3C57-41A1-BBB1-0EAE73D76C95}" /f
    reg delete "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{374DE290-123F-4565-9164-39C4925E467B}" /f
    reg delete "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{754AC886-DF64-4CBA-86B5-F7FBF4FBCEF5}" /f
    reg delete "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"/v  "{7D83EE9B-2244-4E70-B1F5-5393042AF1E4}" /f
    reg delete "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{A0C69A99-21C8-4671-8703-7934162FCF1D}" /f
    reg delete "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{F42EE2D3-909F-4907-8871-4C22FC0BF756}" /f
    reg delete "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /v "{0DDD015D-B06C-45D5-8C4C-F59713854639}" /f
    reg add "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /t REG_EXPAND_SZ /v "Desktop" /d "%USERPROFILE%\Desktop" /f
    reg add "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /t  REG_EXPAND_SZ /v "My Music" /d "%USERPROFILE%\Music" /f
    reg add "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /t REG_EXPAND_SZ /v "Favorites" /d "%USERPROFILE%\Favorites" /f
    reg add "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /t  REG_EXPAND_SZ /v "My Pictures" /d "%USERPROFILE%\Pictures" /f
    reg add "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /t  REG_EXPAND_SZ /v "My Video" /d "%USERPROFILE%\Videos" /f
    reg add "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /t  REG_EXPAND_SZ /v "Documents" /d "%USERPROFILE%\Documents" /f
    reg add "HKLM\$user\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" /t  REG_EXPAND_SZ /v "Personal" /d "%USERPROFILE%\Documents" /f
    reg unload HKLM\$user



 ## Unmount T Drive and Detach VHD
   
    $script5 | diskpart 
}


