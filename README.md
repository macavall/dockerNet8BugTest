# proj1 — Azure Functions (.NET isolated) on Docker

A .NET 8 **dotnet-isolated** Azure Functions app that runs in a **Linux container**.
Instead of the prebuilt `mcr.microsoft.com/azure-functions` image, the **Azure Functions
host is downloaded from GitHub source** (`Azure/azure-functions-host`) and **built locally**
inside the image, then combined with the published function app.

Verified with **Docker Desktop on Windows** (Linux containers).

## Function

| Name    | Trigger      | Auth level | Route              |
| ------- | ------------ | ---------- | ------------------ |
| `http1` | HTTP (GET/POST) | Anonymous | `/api/http1`       |

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) running in **Linux container** mode
- (Optional, for running the app outside Docker) [.NET SDK 8.0](https://dotnet.microsoft.com/download)

## How it works

The [Dockerfile](Dockerfile) uses a 3-stage build:

1. **app-build** (`dotnet/sdk:8.0`) — publishes this function app to `/home/site/wwwroot`.
2. **host-build** (`dotnet/sdk:10.0.103`) — clones `Azure/azure-functions-host` at
   `FUNCTIONS_HOST_REF` and runs `dotnet publish` on the WebHost project. The
   dotnet-isolated worker is pulled in as a NuGet package and copied into `workers/`.
3. **runtime** (`dotnet/aspnet:10.0` + .NET 8 shared frameworks) — combines the
   locally built host with the published app.

> The v4 host targets **.NET 10** (hence the SDK 10.0.103 pin), while the isolated app
> worker runs on **.NET 8**. The worker is a separate process, so the runtime image ships
> both the .NET 10 (host) and .NET 8 (worker) ASP.NET Core runtimes.

## Build

From this folder:

```powershell
docker build -t proj1-func .
```

Build against a different host source ref (branch or tag), e.g. the tip of the v4 branch:

```powershell
docker build --build-arg FUNCTIONS_HOST_REF=release/4.x -t proj1-func .
```

> The host build restores from the public Azure Functions Azure Artifacts feeds
> configured in the cloned repo's `NuGet.config`. The first build takes several minutes
> because it compiles the Functions host from source.

## Run

```powershell
docker run -p 8080:80 proj1-func
```

Then invoke the trigger:

```powershell
curl http://localhost:8080/api/http1
# -> Welcome to Azure Functions!
```

Or open <http://localhost:8080/api/http1> in a browser.

## Build and run with Docker Compose

```powershell
docker compose up --build
```

This maps host port `8080` to container port `80` (see [docker-compose.yml](docker-compose.yml)).

## Useful commands

```powershell
# Run detached
docker run -d --name proj1-run -p 8080:80 proj1-func

# Follow logs
docker logs -f proj1-run

# Stop and remove
docker rm -f proj1-run
```

## Configuration

Runtime environment variables set in the image:

| Variable                                          | Value                 | Purpose                              |
| ------------------------------------------------- | --------------------- | ------------------------------------ |
| `AzureWebJobsScriptRoot`                          | `/home/site/wwwroot`  | Location of the published app        |
| `FUNCTIONS_WORKER_RUNTIME`                        | `dotnet-isolated`     | Worker runtime                       |
| `AzureWebJobsSecretStorageType`                   | `files`               | Avoids needing a storage account     |
| `AZURE_FUNCTIONS_ENVIRONMENT`                     | `Development`         | Enables local/dev host behavior      |
| `AzureFunctionsJobHost__Logging__Console__IsEnabled` | `true`             | Console logging                      |
| `ASPNETCORE_URLS`                                 | `http://+:80`         | Host listen address                  |

To enable Application Insights / Azure Monitor telemetry, pass a connection string
(the exporter is only wired up when this is present — see [Program.cs](Program.cs)):

```powershell
docker run -p 8080:80 -e APPLICATIONINSIGHTS_CONNECTION_STRING="<your-connection-string>" proj1-func
```

## Notes

- `local.settings.json` is **not** copied into the image (excluded via [.dockerignore](.dockerignore)).
