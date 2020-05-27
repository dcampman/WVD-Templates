#region Variables

  #VM Name that we will Image
    $vmName = "Gold-2-Nseries"
  #Resource Groups
    $OldGoldImgRg = "Gold-Image-Dev"
    $NewGoldImgRg = "Gold-Images"
  #Location for Resources (Data Center Region)
    $location = "EastUS"
  #New Image Name
    $imageName = "GOLD-02-IMAGE"

#endregion

#region Functions
Function Test-IsAdmin
{
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}
#endregion

#region CheckReqs

  #Validate script is running as admin
    if(-not(Test-IsAdmin))
    {
        Write-Host -ForegroundColor Red "This script may need to install various modules to run successfully.  In order to complete this task it MUST be running as Admin."
        Write-Host -ForegroundColor Red "The current session is NOT an admin session and cannot continue.  Please open powershell as admin and try again..."
        exit
    }

  #Check if the current version of PS is 5.0 or higher
    $psVer = $host.Version
    if($psVer.Major -lt 5)
    {
        Write-Host -ForegroundColor Red "You are currently running PowerShell version: $psVer"
        Write-Host -ForegroundColor Red "PowerShell version 5 or greater is required for this script to run.  Please upgrade!"
        exit
    }

  #Verify the Az PS module is installed. If not, install it.
    $isInstalled = ""
    $isInstalled = Get-InstalledModule -Name "Az" -ErrorAction SilentlyContinue
    if(-not($isInstalled))
    {
        Write-Host -ForegroundColor Red "The AZ Powershell Module is not installed."
        Write-Host -ForegroundColor Red "Installing the AZ powershell module now."
        Install-Module -Name Az
    }
    Write-Host -ForegroundColor Cyan "Importing the AZ powershell Module"
    Import-Module -Name Az

#endregion



#Connect to Azure
  Connect-AzAccount


#region ResourceGroup

  #Create a resource group
    $rgNotPresent = Get-AzResourceGroup -Name $NewGoldImgRg -ErrorAction SilentlyContinue
    if ($rgNotPresent -eq $null)
    {
      #Resource Group doesn't exist, lets create it!
      New-AzResourceGroup -Name $NewGoldImgRg -Location $location | Out-Null
      do {$newRG = Get-AzResourceGroup -Name $NewGoldImgRg -ErrorAction SilentlyContinue}
      until($newRG -ne $null)
      Write-Host "Resource Group '$NewGoldImgRg' has been created in $location."
    }
    else
    {
      #Resource Group exists, move on!
      Write-Host "A Resource Group named '$NewGoldImgRg' already exists."
      Write-Host "We will create the Virtual Machine Image within this Resource Group."
    }

#endregion


#region Create Azure Image from VM

  #Make sure the VM has been deallocated
    Stop-AzVM -ResourceGroupName $OldGoldImgRg -Name $vmName -Force
  #Set the status of the virtual machine to Generalized
    Set-AzVm -ResourceGroupName $OldGoldImgRg -Name $vmName -Generalized
  #Get the virtual machine from the old Resource Group
    $vm = Get-AzVM -Name $vmName -ResourceGroupName $OldGoldImgRg
  #Create the image configuration
    $image = New-AzImageConfig -Location $location -SourceVirtualMachineId $vm.Id
  #Create the image in the new Resource Group
    New-AzImage -Image $image -ImageName $imageName -ResourceGroupName $NewGoldImgRg

#endregion

#Uncomment if you want to disolve the gold image resource group
#Remove-AzResourceGroup -Name $OldGoldImgRg -force