@{
    RootModule        = 'TalosHelper.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b3f7a2c1-8d4e-4f6a-9c1b-5e2d3f4a6b8c'
    Author            = 'Talos VMware Automation'
    Description       = 'Helper module for Talos Linux VMware deployments'
    RequiredModules   = @('powershell-yaml', 'VCF.PowerCLI')
    FunctionsToExport = @('Get-TalosEnvironment', 'Connect-TalosVCenter')
}
