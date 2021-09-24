$global:ESXi_Server = "";
$global:ESXi_Protocol = "";
$global:ESXi_Username = "";
$global:ESXi_Password = "";

$global:Default_Down_Action = "suspend";#Default down action for VMs ("stop" = Power Down VM) | ("suspend" = Suspend VM)

$global:Down_Host = "true";             #Do you want to down the Vmware Host Server?
$global:Down_Self = "false";            #Do you want to down this system?
        #NOTE:  If you are running this system (self) on the Vmware Server that is impacted by the outage, you can only choose one of these options to be true.  If both show as true, VMware server will be downed before self.

$global:Time_Routine_Check = 30;        #Time between routine checks of UPS
$global:Time_Failure_Check = 10;        #Time between failure status checks of UPS
$global:Count_Failure_Check = 6;        #Total number of checks in failure state of UPS prior to starting down sequence
$global:Time_Self_Down = 300;           #Time between last VM down and STORM Server (self) down sequence
$global:Time_Host_Down = 300;           #Time between last VM down and VM Host Sever down sequence
$global:Battery_Limit = 45;             #Low Limit for Battery Capacity to Initiate Downing Sequence

#$global:VMs_Running = @();
$global:VMs_Configured = @();
$global:VMs_Configured_Actions = @();
#$global:VMs_for_Suspend = @();
#$global:VMs_for_Stop = @();
#$global:VMs_for_Keep = @();

$global:UPS_State = $null;
$global:UPS_Supply = $null;
$global:UPS_Battery = $null;

function Read-Config-File
{
        $Content_Config_File = Get-Content /etc/safedown.config;
        foreach ($Line in $Content_Config_File)
        {
                $VM_Config = $Line -split ":";
                $global:VMs_Configured += ,$VM_Config[0];
                $global:VMs_Configured_Actions += ,$VM_Config[1];
        }
}

function Connect-ESXi-Server
{
        Connect-VIServer -Server $ESXi_Server -Protocol $ESXi_Protocol -User $ESXi_Username -Password $ESXi_Password;
}

function Check-UPS
{
        while (1)
        {
                $Count_Failure = 0;
                pwrstat -pwrfail -shutdown off;
                pwrstat -lowbatt -shutdown off;
                while (1)
                {
                        $global:UPS_State = pwrstat -status | grep State | sed s/State//g | sed s/\s//g | sed s/\.//g | sed s/\n//g | sed s/\r//g;
                        $global:UPS_Supply = pwrstat -status | grep "Power Supply by" | sed s/'Power Supply by'//g | sed s/\s//g | sed s/\.//g | sed s/\n//g | sed s/\r//g;
                        $global:UPS_Battery = pwrstat -status | grep "Battery Capacity" | sed s/'Battery Capacity'//g | sed s/\.//g | sed s/\s//g | sed s/%//g | sed s/\n//g | sed s/\r//g;
                        Write-Host "$UPS_State -> $UPS_Supply ($UPS_Battery%) | Failure Count = $Count_Failure";
                        if ($UPS_State -eq "PowerFailure" -and $UPS_Supply -eq "BatteryPower")
                        {
                                $Count_Failure++;
                                Write-Host "Power Failure Detected - Entering Failure Monitoring Mode..." | wall;
                                break;
                        }
                        sleep($Time_Routine_Check);
                }
                while ($UPS_State -eq "PowerFailure" -and $UPS_Supply -eq "BatteryPower")
                {
                        $global:UPS_State = pwrstat -status | grep State | sed s/State//g | sed s/\s//g | sed s/\.//g | sed s/\n//g | sed s/\r//g;
                        $global:UPS_Supply = pwrstat -status | grep "Power Supply by" | sed s/'Power Supply by'//g | sed s/\s//g | sed s/\.//g | sed s/\n//g | sed s/\r//g;
                        $global:UPS_Battery = pwrstat -status | grep "Battery Capacity" | sed s/'Battery Capacity'//g | sed s/\.//g | sed s/\s//g | sed s/%//g | sed s/\n//g | sed s/\r//g;
                        Write-Host "$UPS_State -> $UPS_Supply ($UPS_Battery%) | Failure Count = $Count_Failure";
                        if ($UPS_State -eq "PowerFailure" -and $UPS_Supply -eq "BatteryPower"){$Count_Failure++}
                        elseif ($UPS_State -eq "Normal" -and $UPS_Supply -eq "UtilityPower"){break}
                        if ($Count_Failure -ge $Count_Failure_Check){Initiate-Downing-Process}
                        #if ($UPS_Battery -lt $Battery_Limit){Initiate-Downing-Process}
                        sleep($Time_Failure_Check);
                }
        }
}

function Initiate-Downing-Process
{
        Write-Host "Power Not Restored! - Initiating Downing Process..." | wall;
        [System.Collections.ArrayList]$VMs_Running = Get-VM | Where-Object {$_.PowerState -eq "PoweredOn"} | ForEach-Object {$_.Name};
        for ($Index_VM=0; $Index_VM -lt $global:VMs_Configured.Length; $Index_VM++)
        {
                if ($VMs_Configured_Actions[$Index_VM] -eq "suspend" -and $VMs_Running.Contains($global:VMs_Configured[$Index_VM]))
                {
                        $Scoped_VM = $VMs_Configured[$Index_VM];
                        Write-Host "Suspending $Scoped_VM";
                        Suspend-VM -VM $Scoped_VM -Confirm:$false;
                        $VMs_Running.Remove($Scoped_VM);
                }
                elseif ($VMs_Configured_Actions[$Index_VM] -eq "stop" -and $VMs_Running.Contains($global:VMs_Configured[$Index_VM]))
                {
                        $Scoped_VM = $VMs_Configured[$Index_VM];
                        Write-Host "Stopping $Scoped_VM";
                        Stop-VM -VM $Scoped_VM -Confirm:$false;
                        $VMs_Running.Remove($Scoped_VM);
                }
                elseif ($VMs_Configured_Actions[$Index_VM] -eq "keep" -and $VMs_Running.Contains($global:VMs_Configured[$Index_VM]))
                {
                        $Scoped_VM = $VMs_Configured[$Index_VM];
                        Write-Host "Keeping $Scoped_VM";
                        $VMs_Running.Remove($Scoped_VM);
                }
        }

        foreach ($Remaining_VM in $VMs_Running)
        {
                Write-Host "$Remaining_VM Still Running";
                if ($global:Default_Down_Action -eq "suspend")
                {
                        Write-Host "Suspending (Default Action) $Remaining_VM";
                        Suspend-VM -VM $Remaining_VM -Confirm:$false;
                }
                elseif ($global:Default_Down_Action -eq "stop")
                {
                        Write-Host "Stopping (Default Action) $Remaining_VM";
                        Stop-VM -VM $Remaining_VM -Confirm:$false;
                }
        }

        if ($Down_Host -eq "true")
        {
                sleep($Time_Host_Down)
                Write-Host "Powering Down Vmware Host...";
                Stop-VMHost 10.1.0.4 -Force -Reason "Power Failure Detected by STORM" -RunAsync;
        }
        if ($Down_Self -eq "true")
        {
                sleep($Time_Self_Down);
                Write-Host "Powering Down Self...";
                shutdown now;
        }
        exit;
}

function Inventory-VMs
{
        $global:VMs_Running = Get-VM | Where-Object {$_.PowerState -eq "PoweredOn"};
}

Read-Config-File;
Connect-ESXi-Server;
Check-UPS;
