﻿param(
	[Parameter(mandatory = $false)]
	[object]$WebHookData
)

# If runbook was called from Webhook, WebhookData will not be null.
if ($WebHookData)
{
	# Collect properties of WebhookData
	$Input = (ConvertFrom-Json -InputObject $WebHookData.RequestBody)
}
else
{
	Write-Error -Message 'Runbook was not started from Webhook' -ErrorAction stop
}

#region variables
#Host start threshold meaning the number of available sessions to trigger a host start or shutdown
	$serverStartThreshold = $Input.UserSessionBuffer
#Get Peak time and Threshold from LogicApp Webhook Data
	$usePeak = $Input.UsePeak
	$peakServerStartThreshold = $Input.PeakUserSessionBuffer
	$startPeakTime = $Input.PeakStart
	$endPeakTime = $Input.PeakEnd
	$utcoffset = $Input.utcOffset
	$peakDay = $Input.PeakDays
#Azure automation encrypted variables for TenantID and Subscription ID
	$aadTenantId = Get-AutomationVariable -Name 'AADTenantId'
	$azureSubId = Get-AutomationVariable -Name 'AzureSubId'
#Host Resource Group
	$sessionHostRg = Get-AutomationVariable -Name 'SessionHostRG'
#Tenant Name
	$tenantName = Get-AutomationVariable -Name 'TenantName'
#Host Pool Name
	$hostPoolName = $Input.HostpoolName
#endregion

#region Functions
function Start-SessionHost
{
	param
	(
		$SessionHosts,
		$sessionsToStart
	)

	# Number of off hosts accepting connections
	$offSessionHosts = $sessionHosts | Where-Object { $_.status -eq "Unavailable" }
	$offSessionHostsCount = $offSessionHosts.count
	Write-Output "Off Session Hosts $offSessionHostsCount"
	Write-Output ($offSessionHost | Out-String)

	if ($offSessionHostsCount -eq 0 )
	{
		Write-Output "Start threshold met, but the status variable is still not finding an available host to start"
		Write-Output "OffSessionHosts = $offSessionHosts"
		Write-Output "SessionHosts = $SessionHosts"
		Write-Output "SessionsToStart = $sessionsToStart"
	}
	else
	{
		if ($sessionsToStart -gt $offSessionHostsCount)
		{
			$sessionsToStart = $offSessionHostsCount
		}
		$counter = 0
		Write-Output "Conditions met to start a host"
		while ($counter -lt $sessionsToStart)
		{
			$startServerName = ($offSessionHosts | Select-Object -Index $counter).SessionHostName
			Write-Output "Server that will be started $startServerName"
			try
			{
				# Start the VM
				$creds = Get-AutomationPSCredential -Name 'WVD-AutoScale-cred'
				Connect-AzAccount -ErrorAction Stop -ServicePrincipal -SubscriptionId $azureSubId -TenantId $aadTenantId -Credential $creds
				$vmName = $startServerName.Split('.')[0]
				Start-AzVM -ErrorAction Stop -ResourceGroupName $sessionHostRg -Name $vmName
			}
			catch
			{
				$ErrorMessage = $_.Exception.message
				Write-Error ("Error starting the session host: " + $ErrorMessage)
				Break
			}
			$counter++
		}
	}
}

function Stop-SessionHost
{
	param
	(
		$SessionHosts,
		$sessionsToStop
	)
	## Get computers running with no users
	$emptyHosts = $sessionHosts | Where-Object { $_.Sessions -eq 0 -and $_.Status -eq 'Available' }
	$emptyHostsCount = $emptyHosts.count
	## Count hosts without users and shut down all unused hosts until desire threshold is met
	Write-Output "Evaluating servers to shut down"
	if ($emptyHostsCount -eq 0)
	{
		Write-Error "Error: No hosts available to shut down"
	}
	else
	{
		if ($sessionsToStop -gt $emptyHostsCount)
		{
			$sessionsToStop = $emptyHostsCount
		}
		$counter = 0
		Write-Output "Conditions met to stop a host"
		while ($counter -lt $sessionsToStop)
		{
			$shutServerName = ($emptyHosts | Select-Object -Index $counter).SessionHostName
			Write-Output "Shutting down server $shutServerName"
			try
			{
				# Stop the VM
				$creds = Get-AutomationPSCredential -Name 'WVD-AutoScale-cred'
				Connect-AzAccount -ErrorAction Stop -ServicePrincipal -SubscriptionId $azureSubId -TenantId $aadTenantId -Credential $creds
				$vmName = $shutServerName.Split('.')[0]
				Stop-AzVM -ErrorAction Stop -ResourceGroupName $sessionHostRg -Name $vmName -Force
			}
			catch
			{
				$ErrorMessage = $_.Exception.Message
				Write-Error ("Error stopping the VM: " + $ErrorMessage)
				Break
			}
			$counter++
		}
	}
}
#endregion

#region Main Script
## Log into Azure WVD
try
{
	$creds = Get-AutomationPSCredential -Name 'WVD-AutoScale-cred'
	Add-RdsAccount -ErrorAction Stop -DeploymentUrl "https://rdbroker.wvd.microsoft.com" -Credential $creds -ServicePrincipal -AadTenantId $aadTenantId
	Write-Output Get-RdsContext | Out-String
}
catch
{
	$ErrorMessage = $_.Exception.message
	Write-Error ("Error logging into WVD: " + $ErrorMessage)
	Break
}

## Get Host Pool
try
{
	$hostPool = Get-RdsHostPool -ErrorVariable Stop $tenantName $hostPoolName
	Write-Output "HostPool:"
	Write-Output $hostPool.HostPoolName
}
catch
{
	$ErrorMessage = $_.Exception.message
	Write-Error ("Error getting host pool details: " + $ErrorMessage)
	Break
}

## Verify load balancing is set to Depth-first
if ($hostPool.LoadBalancerType -ne "DepthFirst")
{
	Write-Error "Error: Host pool not set to Depth-First load balancing. This script requires Depth-First load balancing to execute"
	exit
}

## Check if peak time and adjust threshold
$date = ((get-date).ToUniversalTime()).AddHours($utcOffset)
$dateTime = ($date.hour).ToString() + ':' + ($date.minute).ToString() + ':' + ($date.second).ToString()
Write-Output "Date and Time"
Write-Output $dateTime
$dateDay = (((get-date).ToUniversalTime()).AddHours($utcOffset)).dayofweek
Write-Output $dateDay
if ($dateTime -gt $startPeakTime -and $dateTime -lt $endPeakTime -and $dateDay -in $peakDay -and $usePeak -eq "yes")
{
	Write-Output "Adjusting threshold for peak hours"
	$serverStartThreshold = $peakServerStartThreshold
}

## Get the Max Session Limit on the host pool
## This is the total number of sessions per session host
$maxSession = $hostPool.MaxSessionLimit
Write-Output "MaxSession:"
Write-Output $maxSession

# Find the total number of session hosts
# Exclude servers that do not allow new connections
try
{
	$sessionHosts = Get-RdsSessionHost -ErrorAction Stop -tenant $tenantName -HostPool $hostPoolName | Where-Object { $_.AllowNewSession -eq $true }
}
catch
{
	$ErrorMessage = $_.Exception.message
	Write-Error ("Error getting session hosts details: " + $ErrorMessage)
	Break
}

## Get current active user sessions
$currentSessions = 0
foreach ($sessionHost in $sessionHosts)
{
	$count = $sessionHost.sessions
	$currentSessions += $count
}
Write-Output "CurrentSessions"
Write-Output $currentSessions

## Number of running and available session hosts
## Host that are shut down are excluded
$runningSessionHosts = $sessionHosts | Where-Object { $_.Status -eq "Available" }
$runningSessionHostsCount = $runningSessionHosts.count
Write-Output "Running Session Host $runningSessionHostsCount"
Write-Output ($runningSessionHosts | Out-string)

# Target number of servers required to be running based on active sessions, Threshold and maximum sessions per host
$sessionHostTarget = [math]::Ceiling((($currentSessions + $serverStartThreshold) / $maxSession))

if ($runningSessionHostsCount -lt $sessionHostTarget)
{
	Write-Output "Running session host count $runningSessionHostsCount is less than session host target count $sessionHostTarget, starting sessions"
	$sessionsToStart = ($sessionHostTarget - $runningSessionHostsCount)
	Start-SessionHost -Sessionhosts $sessionHosts -sessionsToStart $sessionsToStart
}
elseif ($runningSessionHostsCount -gt $sessionHostTarget)
{
	Write-Output "Running session hosts count $runningSessionHostsCount is greater than session host target count $sessionHostTarget, stopping sessions"
	$sessionsToStop = ($runningSessionHostsCount - $sessionHostTarget)
	Stop-SessionHost -SessionHosts $sessionHosts -sessionsToStop $sessionsToStop
}
else
{
	Write-Output "Running session host count $runningSessionHostsCount matches session host target count $sessionHostTarget, doing nothing"
}
#endregion