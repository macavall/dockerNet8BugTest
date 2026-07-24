# proj1 — Azure Functions (.NET isolated) on Docker

A .NET 8 **dotnet-isolated** Azure Functions app that runs in a **Linux container**.
Instead of the prebuilt `mcr.microsoft.com/azure-functions` image, the **Azure Functions
host is downloaded from GitHub source** (`Azure/azure-functions-host`) and **built locally**
inside the image, then combined with the published function app.

Verified with **Docker Desktop on Windows** (Linux containers).

## Functions

| Name            | Trigger         | Auth level | Route                  |
| --------------- | --------------- | ---------- | ---------------------- |
| `http1`         | HTTP (GET/POST) | Anonymous  | `/api/http1`           |
| `UploadContent` | HTTP (POST)     | Anonymous  | `/api/UploadContent`   |

`UploadContent` fully reads the request body (`req.Body.CopyToAsync(...)`), which is
required to reproduce the slow-upload timeout described in
[Reproducing the MinRequestBodyDataRate timeout](#reproducing-the-minrequestbodydatarate-timeout).

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

## Reproducing the MinRequestBodyDataRate timeout

This repo can reproduce the Kestrel slow-upload failure:

```
Microsoft.AspNetCore.Server.Kestrel.Core.BadHttpRequestException:
Reading the request body timed out due to data arriving too slowly. See MinRequestBodyDataRate.
```

### Why it happens

Kestrel enforces a minimum request-body data rate (default **240 bytes/sec** with a
**5 second grace period**). The limit is only enforced **while the request body is being
read** — so an endpoint that ignores the body (like `http1`) never triggers it. The
`UploadContent` function reads the full body, so any client that trickles bytes below
240 B/s for more than 5 seconds gets its connection aborted, and the invocation fails
during parameter binding (before user code runs).

### Steps

1. Run the container:

   ```powershell
   docker run -d --name proj1-run -p 8080:80 proj1-func
   ```

2. Run the throttled client ([slow-upload.ps1](slow-upload.ps1)), which opens a raw TCP
   socket, sends a `POST /api/UploadContent` with a fixed `Content-Length`, then sends
   ~8 bytes every 3s (~2.6 B/s — well under 240 B/s):

   ```powershell
   ./slow-upload.ps1 -Port 8080
   ```

   The client aborts partway through with *"An established connection was aborted by the
   software in your host machine"* — this is the server closing the connection.

3. Confirm the server-side exception in the container logs:

   ```powershell
   docker logs --tail 60 proj1-run 2>&1 | Select-String "MinRequestBodyDataRate|BadHttpRequestException"
   ```

### Observed result

```
fail: Function.UploadContent[3]
      Executed 'Functions.UploadContent' (Failed, Duration=~5400ms)
      Microsoft.Azure.WebJobs.Host.FunctionInvocationException: Exception while executing function: Functions.UploadContent
       ---> System.InvalidOperationException: Exception binding parameter 'req'
       ---> Microsoft.AspNetCore.Server.Kestrel.Core.BadHttpRequestException: Reading the request body timed out due to data arriving too slowly. See MinRequestBodyDataRate.
         at Microsoft.AspNetCore.Server.Kestrel.Core.Internal.Http.Http1ContentLengthMessageBody.ReadAsyncInternal(CancellationToken cancellationToken)
```

The `Duration` (~5.4s) matches the default 5-second grace period, and the failure
surfaces as `Exception binding parameter 'req'` — the body read fails before the
function body executes.

### Notes on Azure Functions deployments

- **No host.json or app-setting override exists** for `MinRequestBodyDataRate`. Kestrel
  `Limits` are not bound from configuration, so env vars like
  `Kestrel__Limits__MinRequestBodyDataRate__BytesPerSecond` have no effect.
- The correct worker-side fix (new SDK style) is to configure Kestrel options directly:

  ```csharp
  builder.Services.AddSingleton<IConfigureOptions<KestrelServerOptions>>(
      new ConfigureNamedOptions<KestrelServerOptions>(Options.DefaultName, o =>
          o.Limits.MinRequestBodyDataRate = null));
  ```

  `PostConfigure<KestrelServerOptions>` on the outer host builder does **not** work.
- In a deployed Isolated Worker + ASP.NET Core integration app, requests pass through
  **two** Kestrel servers (platform host on port 80, then the worker). The host's Kestrel
  limit is not customer-configurable, so the recommended production workaround is a
  **direct-to-blob upload via a short-lived SAS URI**, bypassing Kestrel entirely.

### Host-side source fix (applied in this repo)

Because this image builds the Azure Functions host from source, we can fix the root cause
directly on the **host's** client-facing Kestrel (port 80) — the layer a customer cannot
configure on the managed platform. In the host's
`src/WebJobs.Script.WebHost/Program.cs`, `CreateWebHostBuilder()` sets only
`MaxRequestBodySize`, leaving `MinRequestBodyDataRate` at its default (240 B/s, 5s grace).
Setting it to `null` disables the slow-upload monitor:

```csharp
.ConfigureKestrel(o =>
{
    o.Limits.MaxRequestBodySize = ScriptConstants.DefaultMaxRequestBodySize;
    // Disable the host Kestrel's slow-upload rate monitor (MinRequestBodyDataRate,
    // default 240 B/s / 5s grace). This limit is not configurable from the function
    // app, host.json, or app settings, so it must be relaxed here on the host's
    // client-facing Kestrel (port 80).
    o.Limits.MinRequestBodyDataRate = null;
})
```

The fix lives as a real, editable source file at
[host-src-patched/src/WebJobs.Script.WebHost/Program.cs](host-src-patched/src/WebJobs.Script.WebHost/Program.cs)
(vendored from tag `v4.851.100`). The [Dockerfile](Dockerfile) overlays it onto the cloned
host source before publishing, and [proj1.csproj](proj1.csproj) excludes
`host-src-patched/**` from the app's own compilation.

> **Both** Kestrel layers must be relaxed. This host-source change fixes the platform
> Kestrel; the worker's Kestrel is handled separately in [Program.cs](Program.cs) via the
> `IConfigureOptions<KestrelServerOptions>` registration shown above. With both applied, a
> slow upload at ~2.6 B/s completes with `200 OK` instead of failing at ~5s.

> **This is a platform-side change** to `azure-functions-host` and is only possible here
> because the image builds the host from source. A customer on the managed platform cannot
> apply it and should use the direct-to-blob SAS workaround until such a change ships in
> the product.

## Notes

- `local.settings.json` is **not** copied into the image (excluded via [.dockerignore](.dockerignore)).
