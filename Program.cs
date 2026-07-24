using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;
using OpenTelemetry;

internal class Program
{
    private static void Main(string[] args)
    {
        // A1 fix — disable the worker Kestrel's slow-upload rate monitor
        // (MinRequestBodyDataRate, default 240 B/s with a 5s grace period).
        //
        // NOTE: The doc's "old IHostBuilder" snippet that adds a separate
        //   .ConfigureWebHost(webBuilder => webBuilder.ConfigureKestrel(o =>
        //        o.Limits.MinRequestBodyDataRate = null))
        // does NOT work with the ASP.NET Core integration. ConfigureFunctionsWebApplication
        // already owns the worker's web host (it calls ConfigureWebHostDefaults and
        // UseUrls("http://localhost:<random unused port>") — see HttpUriProvider). Adding a
        // second ConfigureWebHost replaces that configuration and drops the UseUrls call, so
        // the worker falls back to ASPNETCORE_URLS (http://+:80) and crashes at startup with
        // "Failed to bind to address http://[::]:80: address already in use" (the host already
        // owns port 80). The host also proxies to the HttpUriProvider port, so binding a
        // different port breaks host->worker forwarding.
        //
        // The correct worker-side registration is via KestrelServerOptions in DI, which flows
        // into the integration's own Kestrel without touching the URL binding.
        var host = new HostBuilder()
            .ConfigureFunctionsWebApplication()
            .ConfigureServices(services =>
            {
                services.AddSingleton<IConfigureOptions<KestrelServerOptions>>(
                    new ConfigureNamedOptions<KestrelServerOptions>(Options.DefaultName, options =>
                    {
                        options.Limits.MinRequestBodyDataRate = null;
                    }));

                var openTelemetry = services.AddOpenTelemetry()
                    .UseFunctionsWorkerDefaults();

                // Only wire up the Azure Monitor exporter when a connection string is provided.
                // This lets the app run locally (e.g. in a Docker container) without one.
                if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING")))
                {
                    openTelemetry.UseAzureMonitorExporter();
                }
            })
            .Build();

        host.Run();
    }
}