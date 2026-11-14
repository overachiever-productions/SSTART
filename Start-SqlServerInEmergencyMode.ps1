#Requires -RunAsAdministrator
Set-StrictMode -Version 1.0;		# 3.0 is better ... but want to make this script as applicable to as many OSes/Versions as possible. 

filter Get-SqlServerInstanceNames {
	$output = @();
	
	$key = Get-Item 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction SilentlyContinue;
	if (($key -eq $null) -or ([string]::IsNullOrEmpty($key.Property))) {
		return $output;
	}
	
	[string[]]$output = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server').InstalledInstances;
	
	$output = $output | ForEach-Object {
		if ($_ -eq 'MSSQLSERVER') { $_ } else {	'MSSQL$' + $_ }
	}
	
	return $output;
}

filter Wait-UntilServiceStatus {
	param (
		[Parameter(Mandatory)]
		[string]$Service,
		[ValidateSet("Running", "Stopped")]
		# only allowed values - as per the docs - are: Running, Stopped, Paused. That's IT.
		[Parameter(Mandatory)]
		[string]$Status,
		[System.TimeSpan]$Timeout = '00:00:30'
	);
	
	$serviceInstance = Get-Service -Name $Service -ErrorAction SilentlyContinue;
	
	if ($null -eq $serviceInstance) {
		throw "Service [$Service] does not exist. Please check spelling.";
	}
	
	if ($serviceInstance.Status -ne $Status) {
		$action = "stop";
		if ($Status -eq "Running") {
			$action = "start";
		}
		
		try {
			if ("Running" -eq $Status) {
				Start-Service -Name $Service -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue | Out-Null;
			}
			else {
				Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue -InformationAction SilentlyContinue | Out-Null;
			}
			
			$serviceInstance.WaitForStatus($Status, $Timeout) | Out-Null;
		}
		catch [System.ServiceProcess.TimeoutException] {
			throw "Timeout Exception Encountered - [$Service] did NOT $action within [$Timeout].";
		}
		catch {
			throw "Unexpected Problem Encountered: " + $PSItem.Exception.Message;
		}
	}
}

filter Get-ConnectionInstance {
	param (
		[Parameter(Mandatory)]
		[string]$InstanceName
	);
	if ($InstanceName -ne "MSSQLSERVER") {
		return ".\$($InstanceName.Replace('MSSQL$', ''))";
	}
	
	return ".";
}

#Clear-Host;

# ====================================================================================================
# Step 1 - Enumerate Instances + Assign Target Instance:
# ====================================================================================================
$instances = @( Get-SqlServerInstanceNames );

[string]$target = '';
switch ($instances.Count) {
	0 {
		Write-Host "No SQL Server Instances Found. Terminating.";
		exit;
	}
	1 {
		$target = $instances[0];
		Write-Host "";
		Write-Host "Single Instance of SQL Server Detected. Setting [$target] as target for further processing.";
		Write-Host "";
	}
	default {
		$menu = @"
------------------------------------------------------------------------
  SPECIFY Which SQL Server Instance to Target for Emergency Start: 
{x}------------------------------------------------------------------------

"@;
		
		try {
			[int]$current = 65;
			[string]$options = '';
			$assignments = @{
			};
			foreach ($instance in $instances) {
				$options = $options + "`t$([char]$current) - $instance`n";
				$assignments[[char]$current] = $instance;
				$current++;
			}
			
			$menu = $menu -replace '{x}', $options;
			
			[string]$userInput = Read-Host -Prompt $menu;
			[char]$selected = $userInput.ToUpperInvariant();
			
			$target = $assignments[$selected];
			
			Write-Host "";
			Write-Host "Instance [$target] Selected as target for further processing.";
			Write-Host "";
		}
		catch {
			Write-Host "Invalid Input Specified. Terminating.";
			exit;
		}
	}
}

# ====================================================================================================
# Step 2 - Collect Operation Information:
# ====================================================================================================
$currentDomainUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name;

$menu = @"
------------------------------------------------------------------------
  SPECIFY Operation to Execute against SQL Server Instance [$target]: 
------------------------------------------------------------------------
	A. Reset [sa] Password. 
	B. Add Current User ([$currentDomainUser]) to [sysadmin] Role.
	C. Restore [master] database. 
	D. Restore [msdb] database. 
	E. Repoint all [tempdb] files to a new location. 

	F. NONE of the ABOVE. (Just restart [$target] for single user (only) access via SQLCMD). 
-----------------------------------

"@;

Write-Host "";

$userInput = (Read-Host -Prompt $menu).ToUpperInvariant();
$command = '';

$instanceName = Get-ConnectionInstance -InstanceName $target;
switch ($userInput) {
	'A' {
		$sqlCred = Get-Credential 'sa';
		$command = "& sqlcmd -S$($instanceName) -E -C -d master -Q `"ALTER LOGIN [sa] WITH PASSWORD = '$($sqlCred.GetNetworkCredential().Password)';`" ";
	}
	'B' {
		$command = "& sqlcmd -S$($instanceName) -E -C -d master -Q `"IF NOT EXISTS (SELECT NULL FROM sys.server_principals WHERE [name] = N'$($currentDomainUser)') CREATE LOGIN [$($currentDomainUser)] FROM WINDOWS; ALTER SERVER ROLE [sysadmin] ADD MEMBER [$($currentDomainUser)]; `" ";
	}
	'C' {
		$path = Read-Host -Prompt "Specify COMPLETE path to .bak of [master] database to restore:";
		$path = $path.Replace("`"", "").Replace("'", "");
		
		if (-not (Test-Path -Path $path)) {
			Write-Host "Invalid Path Specified: [$path]. ";
			Write-Host "`tDouble-Check your input and try again. (Hint: Copy + Paste works well.)";
			Write-Host "Terminating.";
			exit;
		}
		
		$command = "& sqlcmd -S$($instanceName) -E -C -d master -Q `"RESTORE DATABASE [master] FROM DISK = N'$path' WITH REPLACE, RECOVERY;`" ";
	}
	'D' {
		$path = Read-Host -Prompt "Specify COMPLETE path to .bak of [msdb] database to restore:";
		$path = $path.Replace("`"", "").Replace("'", "");
		
		if (-not (Test-Path -Path $path)) {
			Write-Host "Invalid Path Specified: [$path]. ";
			Write-Host "`tDouble-Check your input and try again. (Hint: Copy + Paste works well.)";
			Write-Host "Terminating.";
			exit;
		}
		
		$command = "& sqlcmd -S$($instanceName) -E -C -d master -Q `"RESTORE DATABASE [msdb] FROM DISK = N'$path' WITH REPLACE, RECOVERY;`" ";
	}
	'E' {
		$path = Read-Host -Prompt "Specify new Path for ALL tempdb files - e.g., [D:\SqlData]:";
		$path = $path.Replace("`"", "").Replace("'", "");
		
		if ($path.EndsWith("\", "OrdinalIgnoreCase" )) {
			$path = $path.TrimEnd('\');
		}
		
		if (-not (Test-Path $path)){
			Write-Host "Invalid Path Specified: [$path].";
			Write-Host "`tDouble-Check your input and try again. (Hint: Copy + Paste works well.)";
			Write-Host "Terminating.";
			exit;
		}

		$command = "& sqlcmd -S$($instanceName) -E -C -d master -Q `"ALTER DATABASE [tempdb] MODIFY FILE (NAME = tempdev, FILENAME = '$path\tempdb.mdf'); ALTER DATABASE [tempdb] MODIFY FILE (NAME = templog, FILENAME = '$path\templog.ldf'); `" ";
	}
	'F' {
	}
	default {
		Write-Host "Invalid Option Specified. Terminating.";
		exit;
	}
}

$status = Get-Service $target;

if (($status).Status -eq 'Running') {
	
	Write-Host "";
	Write-Host "Current SQL Server Instance [$target] is Running. Type 'STOP' to Confirm that you wish to STOP this instance: ";
	$stop = Read-Host;
	
	if ($stop.ToUpperInvariant() -notin ("STOP", "'STOP'")) {
		Write-Host "";
		Write-Host "Terminating.";
		exit;
	}
}

if (($status).Status -eq 'Running') {
	
	$sqlAgentService = "SQLSERVERAGENT";
	$targetService = "MSSQLSERVER";
	if ('MSSQLSERVER' -ne $target) {
		$sqlAgentService = "SQLAgent`$$($target)";
		$targetService = "MSSQL`$$($target)";
	}
	
	Write-Host "";
	Write-Host "	Stopping SQL Server Agent and SQL Server Service...";
	Wait-UntilServiceStatus -Service $sqlAgentService -Status Stopped;
	Wait-UntilServiceStatus -Service $target -Status Stopped;
	Write-Host "		Stopped.";
	Write-Host "";
}

try {
	
	Write-Host "";
	Write-Host "	Restarting SQL Server Service in Single-User Mode...";
	
	Invoke-Command -ScriptBlock {
		net start $target /mSQLCMD /f /T3608 /x;  
	}
	
	Write-Host "";
	Write-Host "	Restart (in SINGLE USER Mode) Complete.";
	if (-not ([string]::IsNullOrWhiteSpace($command))) {
		Invoke-Expression -Command $command -InformationAction SilentlyContinue | Out-Null;
	}
	else {
		Write-Host "";
		Write-Host "	[$target] is accessible via sqlcmd.exe "
		Write-Host "		(e.g., 'sqlcmd -S$($instanceName) -E -C -d master -Q `"SELECT @@SERVERNAME`"; ') ";
	}
}
catch {
	Write-Host "Unexpected Exception:`n`n`t$_";
}
finally {
	if (-not ([string]::IsNullOrWhiteSpace($command))) {
		Write-Host "";
		Write-Host "	Target Operations Completed.";
		
		if ('C' -eq $userInput) {
			Write-Host "";
			Write-Host "	[master] database restored (which automatically causes SQL Service to STOP).";
		}
		else {
			Write-Host "";
			Write-Host "Stopping [$target]...";
			Invoke-Expression -Command "& sqlcmd -S$($instanceName) -E -C -d master -Q `"SHUTDOWN WITH NOWAIT;`" ";
			
			Write-Host "	SQL Server Instance [$target] (in Single User Mode) Stopped.";
			Write-Host "";
		}
	}
}

Write-Host "";
Write-Host "	NOTE: Start-SqlServerInEmergencyMode does NOT restart [$target] (in normal mode). You must do this MANUALLY. ";
# SIG # Begin signature block
# MIIq9gYJKoZIhvcNAQcCoIIq5zCCKuMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDXZ6K0pSlVuVFk
# TXYPyEXSrZYcwZHbLsCboSkbIMjpOaCCJVkwggVyMIIDWqADAgECAhB2U/65Pdnn
# 6SYyrNYKvqw4MA0GCSqGSIb3DQEBDAUAMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQK
# ExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIFRpbWVzdGFt
# cGluZyBSb290IFI0NTAeFw0yMDAzMTgwMDAwMDBaFw00NTAzMTgwMDAwMDBaMFMx
# CzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQD
# EyBHbG9iYWxTaWduIFRpbWVzdGFtcGluZyBSb290IFI0NTCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBALp0M+wn3BI4IRvF02Eo1lq8T9+LzJGEQyRXvGQh
# vDscHz1PjK0Ht/PF1wLpERSCmqq0lHI7cQ0a72hrhXmOr2bqWJgNusF8edL/zbNv
# MUXQBXQEAHJqJ364Nz86iO2Xg/WrNU0Pn1k79S/fWcV8pTJ2YJbI7e74BH4ZUXKo
# v0RBerx7HjsAm7y64Ja/kP6Nm8NyiwAS+CA6YDj3wcyFivuHeS6hKyDmy6CFkSO2
# xCgHVCje7BAxT4ryzRQfHt1VHOooMUz5IWqozfOWZ/oBQZvNDwtof7ve8UPqF+Ww
# 3HAis2k2WXRrxuWJKnzlC4Fdqz+PuNF2cvN8oqnil0G/zIxF/mHJ9mwHCwAE6BUj
# T4IqLfbvw/oRNkih0f16OTo0XaMsDpt3UCA0QN2xAzGtX+lih3OWA2H3lLDZXGxP
# 5xTF4fF7DSOczXCMHWreSi2LKrvbQhQFB6r7FNwx0/YfbMu+aGZEcE1tF/lx6wVz
# jpGSdetoXB72RGEYKWLdF2aI7Ci6SW/bPnf+uTEfdRwYoqZHvdjuSIU7/bPiDz8q
# mMaa+oJvsaWlhh1aOvqkbHQPd1Jhan+HKd45m4vus0VgMCSXFRIqhTCTJqyWpi3o
# cG0LqTKtLJsoCnZC8lVhUZiU3u32xRdvPBUQsA6tsN7FFvRl0cwvWlYIz5nE8FWR
# wix5AgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBhjAPBgNVHRMBAf8EBTADAQH/MB0G
# A1UdDgQWBBRGshx34XsV8KU5oXDe0cQu6m2y3jANBgkqhkiG9w0BAQwFAAOCAgEA
# FnwKZ0oDPJMqPhxPRlWwmp6I4etT/UxVeYT5bLafqQq2iatUBxQWSkla9LguhhTE
# fhmJ+YeIvOyy0pWM4Az58pRmpphXG6Hf0XF9jLX4cQLdE7a++rAxwyxn6xoYDhpN
# 3CzPMVxhKKmd42osrlBLDjrQafuKNETffkuOGpAJ2jHayi+l9/Q3LDUNGmLNPHs8
# VndllVyUc3CfYS9pZCMdTHkHwhd8Ou2qbXEDFGJFzLc+VNhRcULqO5JCpS9UgaOw
# DFZYVrvkmO5mxxH5qEUX4mUqit7iqM7FLfb1zq3w4woJ3VN7bKlshn6h3jY1AA9f
# gP1Fu3FmQ9RELNC7AU6Znj5N4V5WHwV6gh2yyy2lM7k55cS32kLhvdCUQoD6GJQ7
# k0OoyJQ6bX6d/E+gwtPlpaoQJm8GIlvgAeJKvxnlRJ6wrasZ0s3rR8RigezwwnqN
# TP3CJbe8LHCOqq1S9BQ8qngdBNPJ1SWCp1rLjHwfVwI7hxvI1/lUGh3KGksnseJK
# 7+eaQBRPpTyf1aO+lDWcwtc/KO6kFytDvWSn16/pU+endx7FEhsx4kvGf54c7qM6
# lFBdplAGUl5FAyu0AODB7dgNwa67SQmBglpCQ6+ZY7gU0TyL3dXwVO1yZ8L2yj41
# hIeADVKVUEHWsg0ZQC+2E033sWDUdsVXOW5aol4KedwwggXhMIIDyaADAgECAhB5
# w2lRigPnF+NXyyeBVD75MA0GCSqGSIb3DQEBCwUAMHsxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNzA1BgNVBAMMLlNTTC5jb20gRVYgQ29kZSBTaWduaW5nIEludGVybWVkaWF0
# ZSBDQSBSU0EgUjMwHhcNMjQxMjE5MDUzMzAxWhcNMjcwNzIyMTgwNzQ2WjCB7TEL
# MAkGA1UEBhMCVVMxEzARBgNVBAgMCldhc2hpbmd0b24xEDAOBgNVBAcMB1Nwb2th
# bmUxJzAlBgNVBAoMHk92ZXJBY2hpZXZlciBQcm9kdWN0aW9ucywgTExDLjEUMBIG
# A1UEBRMLNjAzIDAzMSAxMzIxJzAlBgNVBAMMHk92ZXJBY2hpZXZlciBQcm9kdWN0
# aW9ucywgTExDLjEdMBsGA1UEDwwUUHJpdmF0ZSBPcmdhbml6YXRpb24xGzAZBgsr
# BgEEAYI3PAIBAgwKV2FzaGluZ3RvbjETMBEGCysGAQQBgjc8AgEDEwJVUzB2MBAG
# ByqGSM49AgEGBSuBBAAiA2IABEaT2iHLx2H7qluhjuRQN4bSBrEDdNFpbKn4zYJl
# 1QTsSPQGXVMpXfmuO30QXE8Bj97JKLMcHEk90eqYchrpOCxO35yhSTF3VzKp/vjT
# qDWntTIthTpJHwJTtcBhHPZRgaOCAZowggGWMAwGA1UdEwEB/wQCMAAwHwYDVR0j
# BBgwFoAUNr1J/zEs669qQP6ZwBbtuvxI3V8wfQYIKwYBBQUHAQEEcTBvMEsGCCsG
# AQUFBzAChj9odHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJDQS1FVi1Db2Rl
# U2lnbmluZy1SU0EtNDA5Ni1SMy5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6Ly9vY3Nw
# cy5zc2wuY29tMFAGA1UdIARJMEcwBwYFZ4EMAQMwPAYMKwYBBAGCqTABAwMCMCww
# KgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNzbC5jb20vcmVwb3NpdG9yeTATBgNV
# HSUEDDAKBggrBgEFBQcDAzBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3Jscy5z
# c2wuY29tL1NTTGNvbS1TdWJDQS1FVi1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMy5j
# cmwwHQYDVR0OBBYEFM17AdULSnDy7+3v2BZwy2K6ung9MA4GA1UdDwEB/wQEAwIH
# gDANBgkqhkiG9w0BAQsFAAOCAgEAdt/vX17dMyaa1TIjzS1ON9hzvZ1t+PNK4qaf
# 35VUDeDmeoed5zYjzkh9OOMPPKBFXfPb+Kzgyx70NIDrwn+gWwK9d2WpUsWZcQA5
# L+RssfOrO4pbday0rGC3q0qOmFaX1w9xQH8zw7QbzgvWBKl3VWfOgDSUAXtxkd7m
# c92O6mIaoIOLOApuq8+JUfX58sZ6uKRgLubmdDoLVvSQQFnEbHY980KlWM7Pny3k
# DhZn2Tywmmuu8ov7qMyRn6AQnlct089SaPETKDPClH3RNUgs1OLIHw5GLLZTcmFm
# aeICTuMfDci7MmUS4L3bYxcbV7lngl5Ixx7n0tEKSwv14kp7eJRQHUEKel4MuKNs
# z7xdEnbhjzK5nlJywUg6vmRnnX5TBgC8WHrra7BCfVJZi/s2H3Hw4V2eyXieOayz
# OtWvHk9xv7pke1P1k/CCLFzCA7jyu/6WRJtcasCMwldr8PLnaXv8aURTGBeQlPF4
# B3NmjsupDgh1FxoJOlg2LCclw3M/pea9goT8EwFUmROdaJadjSqy3e+Q5WRD/+NO
# NIclqPDWpcoScyA5QzmB6OR/PKE93ehYEO4DNgo2wRufsCk9Y4W1NpH4uybjagGT
# b3fbzqyGd6BjT/uyvsXlOGihFn8vs7vuUOzi9Yhpuv9z+RY7MJxUnx8mimKo9sBw
# oB8a5zYwggXrMIID06ADAgECAghWtinNNLx49jANBgkqhkiG9w0BAQsFADCBgjEL
# MAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMRgw
# FgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xNzA1BgNVBAMMLlNTTC5jb20gRVYgUm9v
# dCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0EgUjIwHhcNMTcwNTMxMTgxNDM3
# WhcNNDIwNTMwMTgxNDM3WjCBgjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFz
# MRAwDgYDVQQHDAdIb3VzdG9uMRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xNzA1
# BgNVBAMMLlNTTC5jb20gRVYgUm9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBS
# U0EgUjIwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCPNmVA4dZNwNe0
# 6Ubaa+ozR81M+X19vr0tPfDbeOGGpdm6CVdo7Vc+oNAIQYPnKEEkH+NyFdABGvte
# cCOyy58548/FTsaSbSbGe7uz2iedCobpgTcF/vBxcezDHOljohcUne8bZ9OFVQIC
# 1knJzFrhsfdvMp/J1DuIQaicvcur2217CR+iTHKQ2isI/M88VM5nD6jPXZYZC8Tj
# cuut0X0dJ++S6xC/W+s7r8+A3cHSlgRben6kqTw4dqRijqA5Xup3z10AWY9mLD4H
# oqMFJhFpl+qFtw+WC0vIQOFQui6Ky/cPmiLnf5o3E83yTRNrIdHAzCLyoUb2RGmc
# ymE1BwBv1mEIEeq6uPbps2DlTbnsnxRmyVdY282HafiKhhIDR79mE3asd300JIWD
# zdeqnJAanyEsf3i3ZLjY6Kb0eLNVy4TSMsR4rqOPYd3OCFOt7Ij8FeSaDeafGnfO
# TI+4FBU9YpyGOAYAZhLkWXZaU8ACmKIQK2hEe455zjNKdqpbgRYbtYrY0AB7XmK0
# CdaGYw6mBZVJuiiLiJOyNBzYpFVutxzQ3plVOyP0IuD5KWYm7CBQd9tKC4++5QJg
# cEFe1K5QOSIUJsuyO3N0VUcHeYE5qDATROUEiq6WEyVCD7lTxJv8zeQc3jz6q9YG
# Sh9nppgwHN0s29wYlVdmxv9ci1b1dwIDAQABo2MwYTAPBgNVHRMBAf8EBTADAQH/
# MB8GA1UdIwQYMBaAFPlgu9Tj1TT2uPUGgCWnc9tGaaieMB0GA1UdDgQWBBT5YLvU
# 49U09rj1BoAlp3PbRmmonjAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZIhvcNAQELBQAD
# ggIBAFazjssKnUmOv6TEkbtmFwVRmHX75VAsep7xFPqr04o+/5Epj2OL2LSpVAEN
# vpOGL/lKbcde9Vf5ylUcEr5HDzbF32q323XCRyV/ufFj+GgtVQTR8o2wpM+8PF4f
# eOeloCBwsATFt/dyp94iDb0zJUaMZJIm4z4uY5bam4w9+BgJ1wPMfYaC4MoEB1FQ
# 1/+S1Qzv2oafmdfrt69o4jkmlLpot7+D0+p6Zz1iZ64l5XLo4uTsrhL2Sys8n+mw
# QPM4VLP9t2jI2saPUTyy+5HcHOebneG3DXKP4qTEqXj56xSsxkMFwmU5KBgCw4Ky
# nQW+Ze2WX2V0PPsJNS57nBP9Gw9dx22BOlYPzDvhrwIvIqxGykY8oBxM1kS0Xi5c
# FWYJ4SYp/sZSYbqxc//DDJzlbGqUPxTKQBaVhPNZqaxfTGGTbdE7zKKVDCKmZ2dE
# LrnZ0opBs2YLWvt9I6XyGrD/3puDlC7RP9+St5GvBTtlx6Bssc1iEsOQG+MlzjS8
# b3d2sRDD9wUawNavdGJIF3eSaZBhHN6VgHRUjxgcw/MD0L+kQ3WGUxh6Ci4JHDaf
# kf2CiiJL0Q5QJd3LAwwXyYMACE41TYqL7fAClGYsRH/LlSeWF60JMKy2cRduixf2
# HAnULTuYpXHTVBPZYPP1S2ZP+vHuIBKNtKxXsUVjoax2qcL7MIIGhDCCBGygAwIB
# AgIRAIRyP7gwDfuodbM7V8wmN4IwDQYJKoZIhvcNAQEMBQAwXjELMAkGA1UEBhMC
# QkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExNDAyBgNVBAMTK0dsb2JhbFNp
# Z24gT2ZmbGluZSBSNDUgVGltZXN0YW1waW5nIENBIDIwMjUwHhcNMjUxMDE1MDcy
# NDU2WhcNMzcwMTEwMDAwMDAwWjBdMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xv
# YmFsU2lnbiBudi1zYTEzMDEGA1UEAxMqR2xvYmFsc2lnbiBSNDUgVFNBIGZvciBB
# dXRoZW50aWNvZGUgMjAyNTEwMIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKC
# AYEAo5qib0LzOmONbaHJo3ptJ5114tIqUelWQN9js0nuN9WjqaPiWBNL5AOxM/dr
# 0tmxVohS4Chuz4W2U6J3IWR+eKF19ZaRti+3qylKyGrYFaThdEnRlJ+EB1in0Irq
# 6BSGGL7kAGOviVGvH4hlnvFL4N5XhswQ3l1Ha3sXdUOCQ5AiXhZPccq60xCJjEEG
# LdABWJIRKU0mk3ngJGj7X8ryWqCxTUrA//hy2iCY5OscrNA4y+k6xrvFR3pglhgd
# NAATbIDnwByrxLp7VyaYprrUpY0wxuxc1DjRNhrKV+Xf2DK77Huj88GMem2i4WCm
# SrpU/G2qbl5WbzNN/5w9iig1KY1wg3LrHzs3c6RdJh/iHLR9Sjkc7qJLidH3QQzT
# 8TKmZX4weJLb5l17/Z53TFzQ/WO969H3MSCjRIsPJC5umBp70EK7CE3GEfFWtgvY
# ig0hVmak3m81VBKI1zG5LcZxbYt3cQmJhZZaCOvcTjOaIHbYwEzQ8rOEXCHAe8rv
# W1GJAgMBAAGjggG8MIIBuDAOBgNVHQ8BAf8EBAMCB4AwFgYDVR0lAQH/BAwwCgYI
# KwYBBQUHAwgwDAYDVR0TAQH/BAIwADAdBgNVHQ4EFgQUpFtFrgk/9CUBPthTUQJp
# 85AI2BYwHwYDVR0jBBgwFoAUdwI7ATEPHnR3w0jIwwdjVYilO6IwgaUGCCsGAQUF
# BwEBBIGYMIGVMEIGCCsGAQUFBzABhjZodHRwOi8vb2NzcC5nbG9iYWxzaWduLmNv
# bS9nc29mZmxpbmVyNDV0aW1lc3RhbXBjYTIwMjUwTwYIKwYBBQUHMAKGQ2h0dHA6
# Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2dzb2ZmbGluZXI0NXRpbWVz
# dGFtcGNhMjAyNS5jcnQwSgYDVR0fBEMwQTA/oD2gO4Y5aHR0cDovL2NybC5nbG9i
# YWxzaWduLmNvbS9nc29mZmxpbmVyNDV0aW1lc3RhbXBjYTIwMjUuY3JsMEwGA1Ud
# IARFMEMwQQYJKwYBBAGgMgEeMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmds
# b2JhbHNpZ24uY29tL3JlcG9zaXRvcnkvMA0GCSqGSIb3DQEBDAUAA4ICAQBwzMXQ
# amU+SQhZibXBp31NqVIF4I/z0kZD0ozcFy205DhbUAu8YViH+c82ypDkH3wk2LLr
# VB/T21VBcfjqDS9p2ormMMBCSJrOB2WBno9HckZzSUgpdPCkH9s7ynoX4RZS/UBL
# 9M2DJVc+hpKbzCNmrQWhkoSTHbTk8/JFhmhiX5HPp+hiB8Pc3cX1zHLTN+uNDBox
# yzJ6tkmevgalUWKNxCHpICYj9lrJ+bVvBDkxBgr9+bfFuamAUwK2SHW6dEtzHp55
# mfeTAJNIORc/95V+h+QM8wFgwtpV1EVB1ze4po3pxcWjSfAZo4qEvyknEQqqf8yD
# mNsBmgH7qg/a4NEbgnS+4QuEqLL+5hZvd+AyJh/nyNw6Rp8lXObSNvahrS23Qm6+
# Fy90gx2wALq86i70p+QYMcADZcO6NQABlqbGh92BzaLYXo7RlC6vMikqGjLgJe4K
# C5dfiA5E/uEIseLYcD2e4RbL/jHs4TGU91Osx3O+S+2dEl65H2HZADgVLJETeXZD
# vUe4WBOiN6ZwmVf9mIBjvHwt4f6GHWcWg5ZYakjdoW+eHKet5xRzkUAJP/wCRCcX
# 9QiyB9WCOLwRWmTycPaLhLO6gt1JgaT8xsX97eVfaJXs6mkMSzUkz+t++6KWyKOc
# tzAVozo11N9rl4BtPJXVW5VyQTV+bJ059TGLoTCCBqAwggSIoAMCAQICEQCD2oY3
# t58MhAyUe4QKUngfMA0GCSqGSIb3DQEBDAUAMFMxCzAJBgNVBAYTAkJFMRkwFwYD
# VQQKExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIFRpbWVz
# dGFtcGluZyBSb290IFI0NTAeFw0yNTA3MTYwMzA1MDRaFw00MTA3MTYwMDAwMDBa
# MF4xCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTQwMgYD
# VQQDEytHbG9iYWxTaWduIE9mZmxpbmUgUjQ1IFRpbWVzdGFtcGluZyBDQSAyMDI1
# MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEApHcW+O19i+LdAoZFYzS+
# 5X+WYvnWoFqXAfir1hynhUTdH4RW1Db+yOmrQ275jlsQ6bzoZ3nN0CMncZX4E0Qh
# pp6Qvx27+flpfzeMQacD7VciWUiF3TLiu7wT2bBCSENUn3hfGMG4PJvYFvO5o4DA
# 1iNvHhG4oSzctodoJfb4c8EjVahCw/NLizB3ra+NWe2gZBSaZKraMxFt676yqx7R
# cQnjbF4R0OLGovsZt23vU69A5BdoPxdA9zu9rM+qTBsPDVUJexYwEVU0GY7BJ5mU
# WWniyAPHW0Wv4Azk5t7I0XUIjA3+2OGkr0dVBXVBDyEeGBVrYXEdhfVLwuh6HBGJ
# FdIrEY5KoGlpoT+4BBQe4XCH5sv15Uo+M72VKWjPA5Ex3nfFJC4P5FW1SR6olCSa
# IrtnZzc+zgmpSyiD+GcE2udQRQHbDi74enXgazk0+ktpHZ1Z8oTvSaSIREovXSLb
# H3KC8uFIkXucl7XPH7ZGIrmF9eF4zuoo5FIUnsvV60kLqFDzPk+UbLmgZDUCPlFF
# BBehaaNvixEymx9ON2KXev+MfK6OZChqGbrOC2wvvAFHyKlTZbVHdqNiu0u5a2T1
# C9dSTRny1/hxLwcxL9BWPzQLwhsiyXqUzM7uD0lD9+PYMaxUYgoVSxqb4xvPCiVq
# LNabI+WtjEzYfQ0P+6tBTFsCAwEAAaOCAWIwggFeMA4GA1UdDwEB/wQEAwIBhjAT
# BgNVHSUEDDAKBggrBgEFBQcDCDASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQW
# BBR3AjsBMQ8edHfDSMjDB2NViKU7ojAfBgNVHSMEGDAWgBRGshx34XsV8KU5oXDe
# 0cQu6m2y3jCBjgYIKwYBBQUHAQEEgYEwfzA3BggrBgEFBQcwAYYraHR0cDovL29j
# c3AuZ2xvYmFsc2lnbi5jb20vdGltZXN0YW1wcm9vdHI0NTBEBggrBgEFBQcwAoY4
# aHR0cDovL3NlY3VyZS5nbG9iYWxzaWduLmNvbS9jYWNlcnQvdGltZXN0YW1wcm9v
# dHI0NS5jcnQwPwYDVR0fBDgwNjA0oDKgMIYuaHR0cDovL2NybC5nbG9iYWxzaWdu
# LmNvbS90aW1lc3RhbXByb290cjQ1LmNybDARBgNVHSAECjAIMAYGBFUdIAAwDQYJ
# KoZIhvcNAQEMBQADggIBADKj7n7RbuRmMZZYXqlMPRJoR6X1n//quXGLVfOpFoR9
# Ya05L94w0ywBjelyGGf+nAB+CZFQ7gUOd2a2bpfpW8Xw5ArM+YjPEf8AtC4E6Yr1
# 05U1YNjlTSERoWJKc1hkSN5m4dpsYteFykzFQVwX50hYKH3yZ6Vcu6Ha0EA5ofzL
# pi2jK2jbRDCXbFNLi5mO1xKRdB2AzAF0f5C00b4H3d5sCOB8njTvAwaTMGEMeTkL
# WM4Z9Y+3UOtOpo1QuxXbDpXVkLXraG25iL1VtvjxEAy4534nUINB9whORicJJSTL
# ba6fOK2f/1QGWEdewWLHAzE+N5oH0QoNRALpJ5JjIfeInvO+sQdBidnPuLKJ95HT
# j7XyMvJhFZjtbHJGlEWx4UgKcuNKLDLXWALfwQDN2Dey3kTfd4yw4nQdk1PctLLK
# 3F4L2nnLv94BMkpY+Rfl53oOEN4yTvtwCYP+VDuZrktc7NacoTVxZnKGkv8a1akc
# kdOwQZC+i8Ay1VyzMAX/Tb4+r3c65B7cpAtq3OoUijXUJgvZxci6TX78smL2TYy2
# tWn+8G4krnXvy2ELR2XYnKEOS4MVmrSCsjM5nxSrghE10VDXQbEfa93lhikfFoIu
# INKzWDLqvu8ZucmxEufxpHjNnnRVXX/Zv5KQq8pu/MQoOz6DC74n5+O5bSwvT5sg
# MIIG3zCCBMegAwIBAgIQQktqU87HZhQcKmOxpRxBBDANBgkqhkiG9w0BAQsFADCB
# gjELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9u
# MRgwFgYDVQQKDA9TU0wgQ29ycG9yYXRpb24xNzA1BgNVBAMMLlNTTC5jb20gRVYg
# Um9vdCBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eSBSU0EgUjIwHhcNMTkwMzI2MTc0
# NDIzWhcNMzQwMzIyMTc0NDIzWjB7MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4
# YXMxEDAOBgNVBAcMB0hvdXN0b24xETAPBgNVBAoMCFNTTCBDb3JwMTcwNQYDVQQD
# DC5TU0wuY29tIEVWIENvZGUgU2lnbmluZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIz
# MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA8Ko39yshkSBnOjmOFeUh
# uloTKo1R0HM9va4BjBN71n74ZmPt9HsrkvG+Y2v3qDdldg18NKdSsdh48F/pn3d6
# YT6DZuxmzrekPX0ala8dXX/FlUmg2Oq9I+aUP5luJUY4xFWYODyp9OWuedr7dW4A
# HxA/sY8C/0Kukvz101oJJVJjiN1f9JEoFhWrVC6c8d7g29IyaSFnRm1XX5vK0Td/
# p2knHq47al6yxgqgPWAefHbFHKMCZXOEMWXt/lVom6wh0Z2EfuoBz+TnS0wYXWSB
# dzZoxwP4ysQ29p8SbN1EGQvpYH4JK9uaPDbPjqEcAfd1tfZvhwsDWs+Y18soUJel
# ofKoIRz7sUw16hhbFsdFXAAgeW+I01BvcPfF0kMfF5J+MZapQbpD8rnRjcZokuCb
# ioDWedYpX+bAgYryyw5NGDYLdapJNu0jzhfOUYcp0NgMoqJm/9vnkxOLfJTJa1GN
# UtY774oN5L3+OKFaaFnYB+e1NbCQODxbLSIQlwc7srIyYGHGOBVssLq1foP5PLIq
# Hr+tzVinj287bDffrogsR98RHajXFLRlr0/2okmyYXAK/tlOF3hXXokl0sQeStOe
# c+oUaCkCIlH9zxQELv8e85SUnXNQrKqpK0NxIY52MpYoEFkr7D8g6S7m0+NmJRE4
# nGlD6tMkpP+iJeoIDihYnOkCAwEAAaOCAVUwggFRMBIGA1UdEwEB/wQIMAYBAf8C
# AQAwHwYDVR0jBBgwFoAU+WC71OPVNPa49QaAJadz20ZpqJ4wfAYIKwYBBQUHAQEE
# cDBuMEoGCCsGAQUFBzAChj5odHRwOi8vd3d3LnNzbC5jb20vcmVwb3NpdG9yeS9T
# U0xjb20tUm9vdENBLUVWLVJTQS00MDk2LVIyLmNydDAgBggrBgEFBQcwAYYUaHR0
# cDovL29jc3BzLnNzbC5jb20wEQYDVR0gBAowCDAGBgRVHSAAMBMGA1UdJQQMMAoG
# CCsGAQUFBwMDMEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmxzLnNzbC5jb20v
# U1NMY29tLVJvb3RDQS1FVi1SU0EtNDA5Ni1SMi5jcmwwHQYDVR0OBBYEFDa9Sf8x
# LOuvakD+mcAW7br8SN1fMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsFAAOC
# AgEAco/6gUiCkeJggyVbe48vlA+DWM6IJPqZQk4tTjeJ+J+xHq50QHn53sv3/ywl
# EFKYQI9UOP9d0SqpWua3ArvIf+4q0/9/zDY8VSlDXTZJliZdcOfyKwVnR0yZWBkI
# 9rHGT2DS/Di+Aqwl0YgNpSzh3dN9V89qwxlg0m2qXXtE6Fpbg9vIGzYKfgr1ClI2
# eOKa+xNUzJzJR79iTjWvPuG6D8mT7tUgt5a3UHZSNXqdoTsmZDcfzrwDe8RhgVKJ
# zHv+WgUaR67kEsqOVONan7DBivL5X0Zoua/H2T6E0SslEjg9u5oB6t/MZqi2xR9q
# k0ewzgaShK1Dg2qGOVxM4gJLeHOuSyjmpPhhaYDM/zTosC9kAkkNjS4ffeuhhgUP
# 7V5wNOUYAgDrY751Jm2nHJBXB66ZpY430qfDWGyl9OdSIjWnW7tu60jbmnLeqlpi
# SQmekCsSD8g6269oc53Z43nKmPloHermWC6pGGzNmTqazSZwROZmmJwlHhlqx9jz
# 5/+mNXf79X27jILHb31UMrvqmQs56CBRFS+J4yrhxSDzenhOPa8XYpJUjSeMkDfc
# 4ynoQpO2+DsrC5lQuOQ0Bpgj7urftVS7rtvx6t1y+UXtsdpDO4D8b2zf3JFtuKXU
# 73XNZUxkLFnfEy4CG0v6BJPAuzcdH7Ig008zrxahHMCqqIgxggTzMIIE7wIBATCB
# jzB7MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0
# b24xETAPBgNVBAoMCFNTTCBDb3JwMTcwNQYDVQQDDC5TU0wuY29tIEVWIENvZGUg
# U2lnbmluZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIzAhB5w2lRigPnF+NXyyeBVD75
# MA0GCWCGSAFlAwQCAQUAoEwwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwLwYJ
# KoZIhvcNAQkEMSIEIOrd687uTfnWVYAMXjG1sraWJETB1rrgUO+IuyIzhfyrMAsG
# ByqGSM49AgEFAARmMGQCMFBqsGxntwQVmjPsq7n9m4NCbBl/sB7CxIEBKd7A11DX
# mU7RKdJ4IXTrk8miOX5OSQIwEbejavb7Mzb7cmzeBbDrQEVSuraFprFYW9ZELWNq
# FlMfftXjn/zRiLNiva8bMWOmoYIDhDCCA4AGCSqGSIb3DQEJBjGCA3EwggNtAgEB
# MHMwXjELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExNDAy
# BgNVBAMTK0dsb2JhbFNpZ24gT2ZmbGluZSBSNDUgVGltZXN0YW1waW5nIENBIDIw
# MjUCEQCEcj+4MA37qHWzO1fMJjeCMAsGCWCGSAFlAwQCAqCCAVEwGAYJKoZIhvcN
# AQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMTEzMjM1ODUwWjAr
# BgkqhkiG9w0BCTQxHjAcMAsGCWCGSAFlAwQCAqENBgkqhkiG9w0BAQwFADA/Bgkq
# hkiG9w0BCQQxMgQwQRcflBqPvWjR4TAdEiSRAuNSn/rpdO5Mc39wuYSBQA5D/L1D
# jUTZjlXhmnk+elBDMIGoBgsqhkiG9w0BCRACDDGBmDCBlTCBkjCBjwQUHSS/Gatr
# iz8ckaZYxdNUZIEjnS4wdzBipGAwXjELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEds
# b2JhbFNpZ24gbnYtc2ExNDAyBgNVBAMTK0dsb2JhbFNpZ24gT2ZmbGluZSBSNDUg
# VGltZXN0YW1waW5nIENBIDIwMjUCEQCEcj+4MA37qHWzO1fMJjeCMA0GCSqGSIb3
# DQEBDAUABIIBgFqCEmbNubO6ek3lMWIjYl5OQqV9XoMaKrVLtv4WIYDycfGyYJNk
# MXwc9JbaY+C3nikfzMiej6xLWWt7RsB398Ed7bbzlwRY8QTK40buXXYSq/Xa2tWS
# pikc6nOLHCX9zm2cIm4lFY0icf/fPnaO1fUpQ9tCs7NlPqX2edRtimBrmxvAlNy+
# THRECDD93m4YFDa1p2TNESxhWCVnpZ72LuloeIUc3dHguIamu3g4bmU/CMM07x1v
# UUAVe9Q/LozXlpzSDkkh1UdwOW0RLCW8i2rfIMrjO98eMv3N2w6lbm9YETBUdhIl
# 9PVSuxzLC77/4iVE2hW0yVHoFcfEtlbYzp1TdqtK5Qsc6/f9KRyb8s2rMqDof/GE
# CavQ5U0vBFFEVqShtXTXjHEIGUc9i3zAg1nYIMBFkZZPpxBdMtXk55oa44+BuMtK
# qFwAqa03zxHklssK4HS99uvHDgT0jB2gqM295a6xjAVioX06ve4gAfKfjoEYNgwr
# Nuj++CVnUWrCjA==
# SIG # End signature block
