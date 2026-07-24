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
# The host targets net8.0, so we build it with the .NET 8 SDK (matching proj3,
# which uses the prebuilt dotnet-isolated8.0 host image). The global.json in the
# host repo may pin a different SDK patch; the normalization step below rewrites
# it to the .NET 8 SDK actually installed in this image so the build succeeds.
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS host-build

# Branch or tag of Azure/azure-functions-host to build. Must be a ref whose
# host projects target net8.0 so it can be built with the .NET 8 SDK above.
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
# Both the Functions host and the dotnet-isolated app worker run on .NET 8, so a
# single ASP.NET Core 8 runtime image covers both processes (no extra shared
# frameworks need to be copied in).
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:8.0

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
