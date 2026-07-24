# syntax=docker/dockerfile:1

# =============================================================================
# Azure Functions (.NET isolated) on a Linux container.
#
# This image does NOT use the prebuilt mcr.microsoft.com/azure-functions image.
# Instead, the Azure Functions host is downloaded from GitHub source
# (Azure/azure-functions-host) and built locally, then combined with the
# published function app.
#
# Build (from this folder):
#   docker build -t proj1-func .
#
# Run:
#   docker run -p 8080:80 proj1-func
#
# Invoke the anonymous HTTP trigger:
#   http://localhost:8080/api/http1
# =============================================================================

# -----------------------------------------------------------------------------
# Stage 1: Build and publish the .NET isolated function app (proj1)
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS app-build
WORKDIR /src

# Restore first for better layer caching.
COPY proj1.csproj ./
RUN dotnet restore proj1.csproj

# Publish the app to the script root layout expected by the host.
COPY . ./
RUN dotnet publish proj1.csproj -c Release -o /home/site/wwwroot

# -----------------------------------------------------------------------------
# Stage 2: Download and build the Azure Functions host from GitHub source
#
# The host is built with the exact .NET SDK the Functions team pins in the repo's
# global.json (10.0.103 for the v4 release), even though the host targets net8.0.
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:10.0.103 AS host-build

# Branch or tag of Azure/azure-functions-host to build.
# Override with: docker build --build-arg FUNCTIONS_HOST_REF=release/4.x .
ARG FUNCTIONS_HOST_REF=v4.1052.200

RUN apt-get update \
    && apt-get install -y --no-install-recommends git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /host-src
RUN git clone --depth 1 --branch "${FUNCTIONS_HOST_REF}" \
    https://github.com/Azure/azure-functions-host.git .

# Normalize global.json to the SDK actually installed in this image so the build
# is robust even if FUNCTIONS_HOST_REF is overridden to a different ref.
RUN INSTALLED_SDK="$(dotnet --version)" \
    && sed -i -E "s/(\"version\"[[:space:]]*:[[:space:]]*)\"[0-9][^\"]*\"/\1\"${INSTALLED_SDK}\"/" global.json \
    && cat global.json

# Publish only the WebHost project. The language worker runtimes - including the
# dotnet-isolated worker (Microsoft.Azure.Functions.DotNetIsolatedNativeHost) -
# are pulled in as NuGet packages and copied into the "workers" output folder.
RUN dotnet publish src/WebJobs.Script.WebHost/WebJobs.Script.WebHost.csproj \
    -c Release \
    -o /azure-functions-host

# -----------------------------------------------------------------------------
# Stage 3: Runtime image - locally built host + published function app
#
# The host (v4 release) runs on .NET 10, while the isolated app worker runs on
# .NET 8. Since the worker is a separate process, the image needs BOTH runtimes:
#   - ASP.NET Core 10 runtime  -> the Functions host
#   - ASP.NET Core 8 runtime   -> the dotnet-isolated app worker
# We base on the .NET 10 ASP.NET image and copy the .NET 8 shared frameworks in.
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS dotnet8

FROM mcr.microsoft.com/dotnet/aspnet:10.0

# Add the .NET 8 shared frameworks so the isolated worker process can run.
COPY --from=dotnet8 /usr/share/dotnet/shared/Microsoft.NETCore.App /usr/share/dotnet/shared/Microsoft.NETCore.App
COPY --from=dotnet8 /usr/share/dotnet/shared/Microsoft.AspNetCore.App /usr/share/dotnet/shared/Microsoft.AspNetCore.App

# The Azure Functions host we built from source.
COPY --from=host-build /azure-functions-host /azure-functions-host

# The published function app.
COPY --from=app-build /home/site/wwwroot /home/site/wwwroot

ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    FUNCTIONS_WORKER_RUNTIME=dotnet-isolated \
    AzureWebJobsSecretStorageType=files \
    AZURE_FUNCTIONS_ENVIRONMENT=Development \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true \
    ASPNETCORE_URLS=http://+:80

EXPOSE 80

ENTRYPOINT ["dotnet", "/azure-functions-host/Microsoft.Azure.WebJobs.Script.WebHost.dll"]
