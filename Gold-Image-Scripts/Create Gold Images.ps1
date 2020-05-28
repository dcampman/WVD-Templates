[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true"

#region Variables

  #Resource Group Name
    $GoldresourceGroup = "CAN-GOLD-WVD"

  #Resource Location
    $location = "EastUs"

  #Gold Image VM Name
    $vmNamePrefix = "GOLD"

  #Gold Image Count
    $imageCount = 2

  #Name of virtual network for VM
  #this can be an existing vnet or a new vnet
    $vnetName = "CAN-Gold-VNET"

  #Address Space in CIDR form for the virtual network
    $vnetAddressSpace = "172.17.0.0/16"

  #Name of virtual network for VM
  #this can be an existing vnet or a new vnet
    $subnetName = "GOLD-LAN"
    
  #Address Space in CIDR form for the virtual network
    $subnetAddressSpace = "172.17.1.0/24"

  #Create User object for new VM
    $SecurePassword = ConvertTo-SecureString "LuckyDuck123#" -AsPlainText -Force
    $Credential = New-Object System.Management.Automation.PSCredential ("AzureGoldAdmin", $SecurePassword)

  #Username and password for the gold image virtual machine (Not domain joined)
    #UN: Gold-01\AzureGoldAdmin
    #PW: LuckyDuck123#

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
  
  Write-Host -ForegroundColor Cyan "Connected to Azure"

#region ResourceGroup

  #Create a resource group
    $rgNotPresent = Get-AzResourceGroup -Name $GoldresourceGroup -ErrorAction SilentlyContinue
    if ($rgNotPresent -eq $null)
    {
      #Resource Group doesn't exist, lets create it!
      New-AzResourceGroup -Name $GoldresourceGroup -Location $location | Out-Null
      do {$newRG = Get-AzResourceGroup -Name $GoldresourceGroup -ErrorAction SilentlyContinue}
      until($newRG -ne $null)
      Write-Host "Resource Group '$GoldresourceGroup' has been created in $location."
    }
    else
    {
      #Resource Group exists, move on!
      Write-Host "A Resource Group named '$GoldresourceGroup' already exists."
      Write-Host "We will create the new Virtual network within this Resource Group."
    }

#endregion

#region Networking

    $vnet = Get-AzVirtualNetwork -Name $vnetName -ErrorAction SilentlyContinue
    if ($vnet -ne $null) {$subnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnet -ErrorAction SilentlyContinue}
    if ($vnet -eq $null)
    {
      #Virtual Network doesn't exist, lets create it!
      $LANSubnet = New-AzVirtualNetworkSubnetConfig -Name $subnetName -AddressPrefix $subnetAddressSpace
      New-AzVirtualNetwork -Name $vnetName -ResourceGroupName $GoldresourceGroup -Location $location -AddressPrefix $vnetAddressSpace -Subnet $LANSubnet | Out-Null
      do {$newVnet = Get-AzVirtualNetwork -Name $vnetName -ErrorAction SilentlyContinue}
      until($newVnet -ne $null)
      Write-Host "Virtual Network '$vnetName' has been created with subnet '$subnetName'"
      $vnet = Get-AzVirtualNetwork -Name $vnetName -ErrorAction SilentlyContinue
    }
    elseif ($subnet -eq $null)
    {
      #Subnet doesn't exist, lets create it!
      Add-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnetName -AddressPrefix $subnetAddressSpace | Out-Null
      do {$newSubnet = Get-AzVirtualNetworkSubnetConfig -Name $subnetName -VirtualNetwork $vnetName -ErrorAction SilentlyContinue}
      until($newSubnet -ne $null)
      Write-Host "Subnet '$subnetName' has been created"
    }
    else
    {
      Write-Host "A Virtual Network named '$vnetName' with subnet '$subnetName' already exist"
      Write-host "We will create the new Virtual Machines within this virtual network"
    }

#endregion


for ($imageNum = 1; $imageNum -le $imageCount; $imageNum++)
{
  #Create the Image Name
    $vmName = "$vmNamePrefix-$imageNum"

  #Create a public IP address and specify a DNS name
    $PublicIP = New-AzPublicIpAddress -ResourceGroupName $GoldresourceGroup -Location $location -Name "$vmName-PIP-$(Get-Random)" -AllocationMethod Static -IdleTimeoutInMinutes 4

  #Create an inbound Network Security Group rule for port 3389
    $nsgRuleRDP = New-AzNetworkSecurityRuleConfig -Name "RDP" -Protocol Tcp -Direction Inbound -Priority 300 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow

  #Create a Network Security Group
    $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $GoldresourceGroup -Location $location -Name "$vmName-NSG" -SecurityRules $nsgRuleRDP

  #Create a virtual network card and associate with public IP address and NSG
    $nic = New-AzNetworkInterface -Name "$vmName-NIC" -ResourceGroupName $GoldresourceGroup -Location $location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $PublicIP.Id -NetworkSecurityGroupId $nsg.Id

  #Create a virtual machine configuration
    $VirtualMachine = New-AzVMConfig -VMName $vmName -VMSize "Standard_B4ms" | `
    Set-AzVMOperatingSystem -Windows -ComputerName $vmName -Credential $Credential | `
    Set-AzVMSourceImage -PublisherName "MicrosoftWindowsDesktop" -Offer "Windows-10" -Skus "19h2-evd" -Version "latest" | `
    Set-AzVMOSDisk -CreateOption FromImage | `
    Set-AzVMBootDiagnostic -Disable | `
    Add-AzVMNetworkInterface -Id $nic.Id

    Write-Host -ForegroundColor Cyan "Creating Virtual Machine $vmName"

  #Create a virtual machine
    New-AzVm -ResourceGroupName $GoldresourceGroup -Location $location -VM $VirtualMachine
    Write-Host -ForegroundColor Cyan "Virtual Machine Created"
}