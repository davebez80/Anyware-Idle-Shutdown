# Install-PCoIPAgent.ps1
Configuration InstallPCoIPAgent
{
    param
    (
        [Parameter(Mandatory)]
        [String]$gitLocation,

        [Parameter(Mandatory)]
        [String]$sumoCollectorID
    )
    Node "localhost"
    {
        File Sumo_Directory 
        {
            Ensure          = "Present"
            Type            = "Directory"
            DestinationPath = "C:\sumo"
        }
        # Aim to install the collector first and start the log collection before any 
        # other applications are installed.
        Script Install_SumoCollector
        {
            DependsOn  = "[File]Sumo_Directory"
            GetScript  = { @{ Result = "Install_SumoCollector" } }

            TestScript = { return $false }

            SetScript  = {
                Write-Verbose "Install_SumoCollector"

                $sumo_package = "https://teradeploy.blob.core.windows.net/binaries/SumoCollector_windows-x64_19_182-25.exe"
                $sumo_config = "$using:gitLocation/sumo.conf"	
                $sumo_collector_json = "using:$gitLocation/sumo-agent-vm.json"	
                #$sumo_config = "https://raw.githubusercontent.com/teradici/deploy/sumo/dev/domain-controller/new-agent-vm/sumo.conf"
                #$sumo_collector_json = "https://raw.githubusercontent.com/teradici/deploy/sumo/dev/domain-controller/new-agent-vm/sumo-agent-vm.json"
                $dest = "C:\sumo"
                Invoke-WebRequest -UseBasicParsing -Uri $sumo_config -PassThru -OutFile "$dest\sumo.conf"
                Invoke-WebRequest -UseBasicParsing -Uri $sumo_collector_json -PassThru -OutFile "$dest\sumo-agent-vm.json"
                #
                #Insert unique ID
                collectorID = "$using:sumoCollectorID"
                (Get-Content -Path "$dest\sumo.conf").Replace("collectorID", $collectorID) | Set-Content -Path "$dest\sumo.conf"
                
                $installerFileName = "SumoCollector_windows-x64_19_182-25.exe"
		        Invoke-WebRequest $sumo_package -OutFile "$dest\$installerFileName"
                
                #install the collector
                $command = "$dest\$installerFileName -console -q"
                Invoke-Expression $command
            }
        }

        LocalConfigurationManager
        {
            RebootNodeIfNeeded = $true
        }

        File Download_Directory 
        {
            Ensure          = "Present"
            Type            = "Directory"
            DestinationPath = "C:\WindowsAzure\PCoIPAgentInstaller"
        }

        Script Install_PCoIPAgent
        {
            DependsOn  = "[File]Download_Directory"
            GetScript  = { @{ Result = "Install_PCoIPAgent" } }

            #TODO: Check for other agent types as well?
            TestScript = { if ( Get-Item -path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\PCoIP Standard Agent" -ErrorAction SilentlyContinue )
                            {return $true}
                            else {return $false} }
            SetScript  = {
                Write-Verbose "Install_PCoIPAgent"

                $source = "https://teradeploy.blob.core.windows.net/binaries/PCoIP_agent_release_installer_2.7.0.4060_standard.exe"
                $dest = "C:\WindowsAzure\PCoIPAgentInstaller"
                $installerFileName = "PCoIP_agent_release_installer_2.7.0.4060_standard.exe"
                Invoke-WebRequest $source -OutFile "$dest\$installerFileName"

                #install the agent
                & "$dest\$installerFileName" /S
            }
        }
    }
}

