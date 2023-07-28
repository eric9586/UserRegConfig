# UserRegCompare v1.0

# Script variables, alter to your liking
$registryKey = "Software\Policies\Microsoft\OneDrive"
$registryName = "DisablePersonalSync"
$registryValue = 1
$registryType = "DWORD"

# Fixed variables, please leave be
$TempHive = "HKLM\TempHive"
$BackupPath = "$env:SystemDrive\RegBackup"
$date = Get-Date -Format "yyyyMMdd_HHmmss"
$TempHivePS = $TempHive.Replace("\", ":\")

# Check if HKU PSDrive exists, if not create it
if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
	New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS | Out-Null
}

# Get the list of all users and log off any 'disconnected' users.
$Users = query user
$DisconnectedUsersFound = $false
foreach($User in $Users) {
	# Split the string by spaces
	$UserAttributes = $User -split "\s+"
	# Check if the user is disconnected
	if($UserAttributes[3] -eq 'Disc') {
		try {
			# Get the id of the disconnected user
			$Id = $UserAttributes[2]
			Write-Host "Logging off disconnected user with ID: $Id"
			# Log off the disconnected user
			logoff $Id
			Write-Host "Logged off disconnected user with ID: $Id"
			$DisconnectedUsersFound = $true
		} catch {
			Write-Host "Error logging off user: $($_.Exception.Message)"
		}
	}
}
if (-not $DisconnectedUsersFound) {
	Write-Host "No disconnected users found"
}

# Get currently logged on user
$loggedInUser = (Get-WmiObject -Class Win32_ComputerSystem).Username.Split('\')[1]

try {
	# Default user section
	# Create backup directory if it doesn't exist, then hide it
	if (!(Test-Path -Path $BackupPath -PathType Container)) {
		New-Item -ItemType Directory -Force -Path $BackupPath
	}
	Set-ItemProperty -Path $BackupPath -Name Attributes -Value ([IO.FileAttributes]::Hidden)

	# Check if the hive is loaded
	$hiveLoaded = Test-Path -Path $TempHivePS
	if ($hiveLoaded) {
		Write-Host "reg.exe unload $TempHive"
		reg.exe unload $TempHive
	}

	# Go through each user's registry file under %systemdrive%\Users
	Get-ChildItem "$env:SystemDrive\Users" -Force | ForEach-Object {
		if ($_.PSIsContainer -and $_.Name -ne $loggedInUser) {
			$ntuserPath = Join-Path $_.FullName "ntuser.dat"
			
			if (Test-Path -Path $ntuserPath) {
				# Backup ntuser.dat
				$backupDate = Get-Date -Format "yyyyMMddHHmmss"
				$backupFileName = "$($_.Name)_ntuser_$backupDate.dat"
				$backupFilePath = Join-Path $backupPath $backupFileName
				Write-Host "Copy-Item -Path '$ntuserPath' -Destination '$backupFilePath'"
				Copy-Item -Path "$ntuserPath" -Destination "$backupFilePath"

				# Load the user registry hive
				Write-Host "reg.exe load $TempHive $ntuserPath"
				reg.exe load $TempHive $ntuserPath
				
				# Look for a particular registry key, name, value and type
				if (!(Test-Path -Path "$TempHivePS\$registryKey")) {
					# Create the key if it doesn't exist
					Write-Host "New-Item -Path '$TempHivePS\$registryKey'"
					New-Item -Path "$TempHivePS\$registryKey"
				}

				$currentValue = (Get-ItemProperty -Path "$TempHivePS\$registryKey" -Name $registryName -ErrorAction SilentlyContinue).$registryName

				if ($currentValue -eq $null) {
					# Create the value if it doesn't exist
					Write-Host "New-ItemProperty -Path '$TempHivePS\$registryKey' -Name $registryName -Value $registryValue -PropertyType $registryType -Force"
					New-ItemProperty -Path "$TempHivePS\$registryKey" -Name $registryName -Value $registryValue -PropertyType $registryType -Force
				} elseif ($currentValue -ne $registryValue) {
					# Change the value if it doesn't match
					Write-Host "Set-ItemProperty -Path '$TempHivePS\$registryKey' -Name $registryName -Value $registryValue -Force"
					Set-ItemProperty -Path "$TempHivePS\$registryKey" -Name $registryName -Value $registryValue -Force
				}
				# Unload the hive
				# Garbage collection
				[System.GC]::Collect()
				[System.GC]::WaitForPendingFinalizers()
				Write-Host "reg.exe unload $TempHive"
				reg.exe unload $TempHive
			}
		}
	}
} catch {
	Write-Host "Error in default user section: $($_.Exception.Message)"
}

# HKU section
try {
	# List all loaded hives
	$HKUPath = "Registry::HKU"
	$subKeys = Get-ChildItem -Path $HKUPath

	# Iterate through all loaded hives
	foreach ($subKey in $subKeys) {
		$SID = $subKey.PSChildName
		Write-Host "Currently processing SID: $SID"
	
		# Ignore system profiles, .DEFAULT, and _Classes
		if ($SID -notin @(".DEFAULT", "S-1-5-18", "S-1-5-19", "S-1-5-20") -and $SID -notlike "*_Classes") {
			Write-Host "Valid SID found: $SID"
	
			# The registry path for the current user
			Write-Host "$keyPath = '$SID\$registryKey'"
			$keyPath = "$SID\$registryKey"
	
			# Check if the registry key exists
			if (!(Test-Path "HKU:\$($keyPath)")) {
				# Create the key if it doesn't exist
				Write-Host "Registry key not found for SID $SID. Creating..."
				New-Item -Path "HKU:\$($keyPath)"
			}

			Write-Host "Registry key exists for SID: $SID"

			# Get the current value of the registry property
			$currentValue = Get-ItemProperty -Path "HKU:\$($keyPath)" -Name $registryName -ErrorAction SilentlyContinue

			# If the key doesn't exist or the current value is different from the intended value, perform changes and backup
			if (($null -eq $currentValue) -or ($currentValue.$registryName -ne $registryValue)) {
				# Backup registry settings with a date and time stamp
				Write-Host "Creating backup for SID: $SID"
				$backupFile = Join-Path $BackupPath "Backup_${SID}_${date}.reg"

				# Use Try-Catch
				try {
					# Export the current settings to the backup file
					Write-Host "reg.exe export 'HKU:\$($keyPath)' $backupFile /y"
					reg.exe export "HKU\$($keyPath)" $backupFile /y
				} catch {
					Write-Host "Error during backup: $($_.Exception.Message)"
				}

				# If the registry value doesn't exist or is different from the intended value, create/modify the registry value
				Write-Host "Checking registry value"

				if ($null -eq $currentValue) {
					Write-Host "Creating new registry value"
					New-ItemProperty -Path "HKU:\$($keyPath)" -Name $registryName -Value $registryValue -PropertyType $registryType -Force
				} elseif ($currentValue.$registryName -ne $registryValue) {
					Write-Host "Modifying existing registry value"
					Set-ItemProperty -Path "HKU:\$($keyPath)" -Name $registryName -Value $registryValue -Force
				}
			}
		}
	}
} catch {
	Write-Host "Error in HKU section: $($_.Exception.Message)"
}