#!/usr/bin/env pwsh
using namespace System.IO
using namespace System.Net
using namespace System.Management.Automation


#region    Classes
#Requires -Modules argparser

# .Example
# $fetcher = [GitFetcher]::new()
# $fetcher.Start()

class GitFetcher {
  [string]$AUTHOR = 1
  [string]$REPOSITORY = 2
  [string]$BRANCH = 4
  [string]$outputDirectory = [IO.Path]::GetFullPath([Environment]::CurrentDirectory)
  [string]$localRootDirectory = ''
  [string]$currentDownloadingFile = ''
  [hashtable]$authentication = @{}
  [hashtable]$authenticationSwitch = @{}
  [bool]$doesUseAuth = $false
  [string]$configFile = [IO.Path]::Combine([Environment]::GetFolderPath('UserProfile'), '.download_github')
  [int]$timeout
  [System.Timers.Timer]$timer
  [string]$rootDirectoryForCleanUp

  [void] CheckGithubRepoURLValidity([string]$downloadUrl) {
    $uri = [Uri]::new($downloadUrl)
    if ($uri.Host -ne 'github.com') {
      throw 'Invalid domain: github.com is expected!'
    }
    if ($uri.Segments.Length -lt 3) {
      throw 'Invalid url: https://github.com/user/repository is expected'
    }
  }

  [void] PrintHelpInformation() {
    Write-Host @"
Usage: download [OPTION]...
Example: download --url='https://github.com/user/repository'  --out='~/output'

Resource URL:
--url=URL                     the url of resource to be downloaded

Output:
--out=output_directory        the directory holds your download resource

Authentication:
--auth=username:password      the password can be either you login password of github account or access token
--alwaysUseAuth               if set true, every request is authenticated and in this way we can have more API
                              access rate

Configuration file:
--file=config_file            the default configuration file is the '~/.download_github'

Timeout:
--timeout=number(ms)          timeout specifies the number of milliseconds to exit after the internet is detected disconnected
"@
  }

  [string] FindRootDirectoryForCleanUp([string]$out) {
    $segments = $out -split '/+'
    $path = $segments[0]
    $this.rootDirectoryForCleanUp = $null

    for ($i = 1; $i -lt $segments.Length; $i++) {
      $path = "$path/$($segments[$i])"
      if (-not [IO.Directory]::Exists($path)) {
        $this.rootDirectoryForCleanUp = $path
        break
      }
    }

    return $this.rootDirectoryForCleanUp
  }

  [void] TackleArgs([hashtable]$args) {
    $params = ConvertTo-Params $args -schema @{
      help          = [switch], $false
      url           = [string], ''
      out           = [string], ''
      auth          = [string], ''
      alwaysUseAuth = [switch], $false
      timeout       = [int], 0
      file          = [string], ''
    }

    if ($params['help'] -or ($args.Count -eq 0)) {
      $this.PrintHelpInformation()
      return
    }

    if (-not $params['url']) {
      throw 'Bad option: a URL is needed!'
    } else {
      $this.CheckGithubRepoURLValidity($params['url'])
    }

    if ($params['out']) {
      $this.outputDirectory = $this.Tilde($params['out'])
      if ($this.outputDirectory[-1] -ne '/') {
        $this.outputDirectory += '/'
      }
      $this.rootDirectoryForCleanUp = $this.FindRootDirectoryForCleanUp($this.outputDirectory)
    }

    if ($params['auth']) {
      $auth = $params['auth']
      $colonPos = $auth.IndexOf(':')
      if ($colonPos -eq -1 -or $colonPos -eq $auth.Length - 1) {
        throw 'Bad auth option: username:password is expected!'
      }

      $username, $password = $auth -split ':'
      $this.authentication['auth'] = @{
        username = $username
        password = $password
      }

      if ($params['alwaysUseAuth']) {
        $this.authenticationSwitch = $this.authentication
        $this.doesUseAuth = $true
      }
    }

    if ($params['timeout']) {
      $this.timeout = $params['timeout']
    }

    if ($params['file']) {
      $this.configFile = $this.Tilde($params['file'])
    }
  }

  [bool] DoesNeedReadConfiguration([hashtable]$args) {
    if (-not $args.ContainsKey('auth') -or -not $args.ContainsKey('alwaysUseAuth') -or -not $args.ContainsKey('timeout')) {
      return $true
    }
    return $false
  }

  [void] ReadConfiguration() {
    if ([IO.File]::Exists($this.configFile) -and $this.DoesNeedReadConfiguration($args)) {
      $data = [IO.File]::ReadAllText($this.configFile)
      $config = ConvertFrom-Json $data

      if (-not $args.ContainsKey('auth') -and $config.ContainsKey('auth')) {
        $this.authentication['auth'] = $config['auth']
      }

      if (-not $args.ContainsKey('alwaysUseAuth') -and $config.ContainsKey('alwaysUseAuth')) {
        $this.authenticationSwitch = $this.authentication
        $this.doesUseAuth = $true
      }

      if (-not $args.ContainsKey('timeout') -and $config.ContainsKey('timeout')) {
        $this.timeout = [int]::Parse($config['timeout'])
      }
    }
  }

  [string] PreprocessURL([string]$repoURL) {
    if ($repoURL[-1] -eq '/') {
      return $repoURL.Substring(0, $repoURL.Length - 1)
    }
    return $repoURL
  }

  [hashtable] ParseInfo([hashtable]$repoInfo) {
    $repoURL = $this.PreprocessURL($repoInfo['url'])
    $repoPath = [Uri]::new($repoURL).AbsolutePath
    $splitPath = $repoPath -split '/'
    $info = @{}

    $info['author'] = $splitPath[$this.AUTHOR]
    $info['repository'] = $splitPath[$this.REPOSITORY]
    $info['branch'] = $splitPath[$this.BRANCH]
    $info['rootName'] = $splitPath[-1]

    $info['urlPrefix'] = "https://api.github.com/repos/$($info['author'])/$($info['repository'])/contents/"
    $info['urlPostfix'] = "?ref=$($info['branch'])"

    if ($splitPath[$this.BRANCH]) {
      $info['resPath'] = $repoPath.Substring($repoPath.IndexOf($splitPath[$this.BRANCH]) + $splitPath[$this.BRANCH].Length + 1)
    }

    if (!$repoInfo.ContainsKey('fileName') -or $repoInfo['fileName'] -eq '') {
      $info['downloadFileName'] = $info['rootName']
    } else {
      $info['downloadFileName'] = $repoInfo['fileName']
    }

    if ($repoInfo['rootDirectory'] -eq 'false') {
      $info['rootDirectoryName'] = ''
    } elseif (-not $repoInfo.ContainsKey('rootDirectory') -or $repoInfo['rootDirectory'] -eq '' -or $repoInfo['rootDirectory'] -eq 'true') {
      $info['rootDirectoryName'] = "$($info['rootName'])/"
    } else {
      $info['rootDirectoryName'] = "$($repoInfo['rootDirectory'])/"
    }

    return $info
  }

  [void] CleanUpOutputDirectory() {
    if ($null -ne $this.rootDirectoryForCleanUp) {
      Remove-Item -Recurse -Force $this.rootDirectoryForCleanUp
      return
    }

    if ($this.fileStats['doesDownloadDirectory']) {
      Remove-Item -Recurse -Force $this.localRootDirectory
    } else {
      Remove-Item -Force "$($this.localRootDirectory)$($this.currentDownloadingFile)"
    }
  }

  [void] ProcessClientError([Exception]$exception, [ScriptBlock]$retryCallback) {
    if ($null -eq $exception.Response) {
      Write-Error @"
No internet, try:
- Checking the network cables, modem, and router
- Reconnecting to Wi-Fi
"@
      if ($this.localRootDirectory -ne '') {
        $this.CleanUpOutputDirectory()
      }
      exit
    }

    if ($exception.Response.StatusCode -eq [HttpStatusCode]::Unauthorized) {
      Write-Error 'Bad credentials, please check your username or password(or access token)!'
    } elseif ($exception.Response.StatusCode -eq [HttpStatusCode]::Forbidden) {
      if ($this.authentication.ContainsKey('auth')) {
        Write-Warning 'The unauthorized API access rate exceeded, we are now retrying with authentication......'
        $this.authenticationSwitch = $this.authentication
        $this.doesUseAuth = $true
        & $retryCallback
      } else {
        Write-Error @"
API rate limit exceeded, Authenticated requests get a higher rate limit.
Check out the documentation for more details. https://developer.github.com/v3/#rate-limiting
"@
        if ($this.localRootDirectory -ne '') {
          $this.CleanUpOutputDirectory()
        }
      }
    } else {
      $errMsg = $exception.Message
      if ($exception.Response.StatusCode -eq [HttpStatusCode]::NotFound) {
        $errMsg += ', please check the repo URL!'
      }
      Write-Error $errMsg
    }
    exit
  }

  [hashtable] ExtractFilenameAndDirectoryFrom([string]$path) {
    $components = $path -split '/'
    $filename = $components[-1]
    $directory = $path.Substring(0, $path.Length - $filename.Length)

    return @{
      filename  = $filename
      directory = $directory
    }
  }

  [string] RemoveResPathFrom([string]$path) {
    return $path.Substring([Uri]::UnescapeDataString($this.repoInfo['resPath']).Length + 1)
  }

  [hashtable] ConstructLocalPathname([string]$repoPath) {
    $partialPath = $this.ExtractFilenameAndDirectoryFrom($this.RemoveResPathFrom($repoPath))
    $this.localRootDirectory = "$($this.outputDirectory)$($this.repoInfo['rootDirectoryName'])"
    $localDirectory = "$($this.localRootDirectory)$($partialPath['directory'])"

    return @{
      filename  = $partialPath['filename']
      directory = $localDirectory
    }
  }

  [void] DownloadFile([string]$url, [hashtable]$pathname) {
    $client = [WebClient]::new()
    if ($this.authenticationSwitch.Count -gt 0) {
      $client.Credentials = [NetworkCredential]::new($this.authenticationSwitch['auth']['username'], $this.authenticationSwitch['auth']['password'])
    }

    if (-not [IO.Directory]::Exists($pathname['directory'])) {
      [IO.Directory]::CreateDirectory($pathname['directory']) | Out-Null
    }

    $localPathname = "$($pathname['directory'])$($pathname['filename'])"
    $client.DownloadFile($url, $localPathname)
    $this.fileStats['downloaded']++
    if ($this.fileStats['downloaded'] -lt $this.fileStats['currentTotal']) {
      # Update progress bar
    }

    if ($this.fileStats['downloaded'] -eq $this.fileStats['currentTotal'] -and $this.fileStats['done']) {
      # Update progress bar
      exit
    }
  }

  [void] IterateDirectory([System.Collections.ArrayList]$dirPaths) {
    $url = "$($this.repoInfo['urlPrefix'])$($dirPaths[-1])$($this.repoInfo['urlPostfix'])"
    $client = [WebClient]::new()
    if ($this.authenticationSwitch.Count -gt 0) {
      $client.Credentials = [NetworkCredential]::new($this.authenticationSwitch['auth']['username'], $this.authenticationSwitch['auth']['password'])
    }

    $data = $client.DownloadString($url) | ConvertFrom-Json
    foreach ($item in $data) {
      if ($item.type -eq 'dir') {
        $dirPaths.Add($item.path)
      } elseif ($item.download_url) {
        $pathname = $this.ConstructLocalPathname($item.path)
        $this.DownloadFile($item.download_url, $pathname)
        $this.fileStats['currentTotal']++
        # Set progress bar total
      } else {
        Write-Host $item
      }
    }

    if ($dirPaths.Count -gt 0) {
      $this.IterateDirectory($dirPaths)
    } else {
      $this.fileStats['done'] = $true
    }
  }

  [void] DownloadDirectory() {
    $dirPaths = [System.Collections.ArrayList]::new()
    $dirPaths.Add($this.repoInfo['resPath'])
    $this.IterateDirectory($dirPaths)
  }

  [void] InitializeDownload([hashtable]$paras) {
    $this.repoInfo = $this.ParseInfo($paras)

    if (-not $this.repoInfo.ContainsKey('resPath') -or $this.repoInfo['resPath'] -eq '') {
      if (-not $this.repoInfo.ContainsKey('branch') -or $this.repoInfo['branch'] -eq '') {
        $this.repoInfo['branch'] = 'master'
      }

      $repoURL = "https://github.com/$($this.repoInfo['author'])/$($this.repoInfo['repository'])/archive/$($this.repoInfo['branch']).zip"
      $this.DownloadFile($repoURL, @{ directory = $this.outputDirectory; filename = "$($this.repoInfo['repository']).zip" })
      $this.localRootDirectory = $this.outputDirectory
      $this.currentDownloadingFile = "$($this.repoInfo['repository']).zip"
      $this.fileStats['done'] = $true
      $this.fileStats['currentTotal'] = 1
      # Set progress bar total
    } else {
      $url = "$($this.repoInfo['urlPrefix'])$($this.repoInfo['resPath'])$($this.repoInfo['urlPostfix'])"
      $client = [WebClient]::new()
      if ($this.authenticationSwitch.Count -gt 0) {
        $client.Credentials = [NetworkCredential]::new($this.authenticationSwitch['auth']['username'], $this.authenticationSwitch['auth']['password'])
      }

      $response = $client.DownloadString($url) | ConvertFrom-Json
      if ($response -is [array]) {
        $this.DownloadDirectory()
        $this.fileStats['doesDownloadDirectory'] = $true
      } else {
        $partialPath = $this.ExtractFilenameAndDirectoryFrom([Uri]::UnescapeDataString($this.repoInfo['resPath']))
        $this.DownloadFile($response.download_url, @{ directory = $this.outputDirectory; filename = $partialPath['filename'] })
        $this.localRootDirectory = $this.outputDirectory
        $this.currentDownloadingFile = $partialPath['filename']
        $this.fileStats['done'] = $true
        $this.fileStats['currentTotal'] = 1
        # Set progress bar total
      }
    }
  }

  [void] DetectInternetConnectivity() {
    $dnsServer = '8.8.8.8' # Public DNS server
    if (!(Test-Connection -ComputerName $dnsServer -Count 1 -Quiet)) {
      if ($null -ne $this.timeout) {
        Start-Sleep -Milliseconds $this.timeout
        $this.timer.Stop()
        $this.ProcessClientError([Exception]::new('No internet'), $null)
      }
    }
  }

  [void] Start() {
    $script:args = @{}
    foreach ($arg in $args) {
      $args[$arg.Key] = $arg.Value
    }
    try {
      $this.TackleArgs($args)
      $this.ReadConfiguration()

      if (-not $args.ContainsKey('help') -and $args.Count -gt 0) {
        $this.timer = [System.Timers.Timer]::new(2000)
        $this.timer.AutoReset = $true
        $this.timer.Add_Elapsed({ $this.DetectInternetConnectivity() })
        $this.timer.Start()

        # Initialize progress bar
        Write-Host ''
        $this.InitializeDownload(@{ url = $args['url']; fileName = $args['fileName']; rootDirectory = $args['rootDirectory'] })
      } else {
        $this.timer.Stop()
      }
    } catch {
      Write-Error $_.Exception.Message
      $this.PrintHelpInformation()
    }
  }
}

#endregion Classes
# Types that will be available to users when they import the module.
$typestoExport = @(
  [GitFetcher]
)
$TypeAcceleratorsClass = [PsObject].Assembly.GetType('System.Management.Automation.TypeAccelerators')
foreach ($Type in $typestoExport) {
  if ($Type.FullName -in $TypeAcceleratorsClass::Get.Keys) {
    $Message = @(
      "Unable to register type accelerator '$($Type.FullName)'"
      'Accelerator already exists.'
    ) -join ' - '
    "TypeAcceleratorAlreadyExists $Message" | Write-Debug
  }
}
# Add type accelerators for every exportable type.
foreach ($Type in $typestoExport) {
  $TypeAcceleratorsClass::Add($Type.FullName, $Type)
}
# Remove type accelerators when the module is removed.
$MyInvocation.MyCommand.ScriptBlock.Module.OnRemove = {
  foreach ($Type in $typestoExport) {
    $TypeAcceleratorsClass::Remove($Type.FullName)
  }
}.GetNewClosure();

$scripts = @();
$Public = Get-ChildItem "$PSScriptRoot/Public" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += Get-ChildItem "$PSScriptRoot/Private" -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
$scripts += $Public

foreach ($file in $scripts) {
  Try {
    if ([string]::IsNullOrWhiteSpace($file.fullname)) { continue }
    . "$($file.fullname)"
  } Catch {
    Write-Warning "Failed to import function $($file.BaseName): $_"
    $host.UI.WriteErrorLine($_)
  }
}

$Param = @{
  Function = $Public.BaseName
  Cmdlet   = '*'
  Alias    = '*'
  Verbose  = $false
}
Export-ModuleMember @Param
