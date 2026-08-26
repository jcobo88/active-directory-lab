Import-Module ActiveDirectory

$csvPath = "C:\Lab\Data\new-users.csv"
$reportDirectory = "C:\Lab\Reports"

# Verify the input CSV exists
if (-not (Test-Path $csvPath)) {
    Write-Error "CSV file not found: $csvPath"
    exit
}

# Create report directory if needed
if (-not (Test-Path $reportDirectory)) {
    New-Item -Path $reportDirectory -ItemType Directory -Force | Out-Null
}

$users = Import-Csv $csvPath

if (-not $users) {
    Write-Error "The CSV file contains no users."
    exit
}

# Verify required CSV columns exist
$requiredColumns = @(
    "FirstName",
    "LastName",
    "Department"
)

$csvColumns = $users[0].PSObject.Properties.Name

$missingColumns = $requiredColumns |
    Where-Object { $_ -notin $csvColumns }

if ($missingColumns) {
    Write-Error "Missing required CSV columns: $($missingColumns -join ', ')"
    exit
}

# Map departments to Active Directory groups
$groupMap = @{
    "Accounting"      = "GG_Accounting_Users"
    "Human Resources" = "GG_HR_Users"
    "IT"              = "GG_IT_Users"
    "Management"      = "GG_Management_Users"
    "Sales"           = "GG_Sales_Users"
}

$temporaryPassword = Read-Host `
    "Enter temporary password for new users" `
    -AsSecureString

$results = foreach ($user in $users) {

    $username = $null

    try {

        # Validate required user information
        if ([string]::IsNullOrWhiteSpace($user.FirstName) -or
            [string]::IsNullOrWhiteSpace($user.LastName) -or
            [string]::IsNullOrWhiteSpace($user.Department)) {

            throw "FirstName, LastName, and Department are required."
        }

        # Verify department is supported
        if (-not $groupMap.ContainsKey($user.Department)) {
            throw "Unknown department: $($user.Department)"
        }

        # Generate username: first initial + last name
        $username = (
            $user.FirstName.Substring(0,1) +
            $user.LastName
        ).ToLower()

        $ouPath = "OU=$($user.Department),OU=Users,OU=COBO,DC=cobo,DC=test"

        $groupName = $groupMap[$user.Department]

        # Check for existing account
        $existingUser = Get-ADUser `
            -Filter "SamAccountName -eq '$username'"

        if ($existingUser) {

            [PSCustomObject]@{
                Name       = "$($user.FirstName) $($user.LastName)"
                Username   = $username
                Department = $user.Department
                Group      = $groupName
                Status     = "Skipped"
                Details    = "User already exists"
            }

            continue
        }

        # Verify the Organizational Unit exists
        Get-ADOrganizationalUnit `
            -Identity $ouPath `
            -ErrorAction Stop |
            Out-Null

        # Verify the security group exists
        Get-ADGroup `
            -Identity $groupName `
            -ErrorAction Stop |
            Out-Null

        # Create the Active Directory user
        New-ADUser `
            -Name "$($user.FirstName) $($user.LastName)" `
            -GivenName $user.FirstName `
            -Surname $user.LastName `
            -DisplayName "$($user.FirstName) $($user.LastName)" `
            -SamAccountName $username `
            -UserPrincipalName "$username@cobo.test" `
            -Department $user.Department `
            -Path $ouPath `
            -AccountPassword $temporaryPassword `
            -Enabled $true `
            -ChangePasswordAtLogon $true `
            -ErrorAction Stop

        # Add the user to the department security group
        Add-ADGroupMember `
            -Identity $groupName `
            -Members $username `
            -ErrorAction Stop

        [PSCustomObject]@{
            Name       = "$($user.FirstName) $($user.LastName)"
            Username   = $username
            Department = $user.Department
            Group      = $groupName
            Status     = "Created"
            Details    = "Account provisioned successfully"
        }
    }

    catch {

        [PSCustomObject]@{
            Name       = "$($user.FirstName) $($user.LastName)"
            Username   = $username
            Department = $user.Department
            Group      = $groupMap[$user.Department]
            Status     = "Failed"
            Details    = $_.Exception.Message
        }
    }
}

# Display provisioning results
$results |
    Format-Table Name,Username,Department,Status -AutoSize

# Export provisioning report
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$reportPath = Join-Path `
    $reportDirectory `
    "Provisioning-$timestamp.csv"

$results |
    Export-Csv `
        -Path $reportPath `
        -NoTypeInformation

Write-Host ""
Write-Host "Provisioning report saved to:"
Write-Host $reportPath
