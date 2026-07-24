using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;

internal class Program
{
    private static void Main(string[] args)
    {
        // A1 fix (old IHostBuilder style): configure the worker's Kestrel via
        // ConfigureWebHost -> ConfigureKestrel, which is the authoritative
        // registration path the worker's GenericWebHostBuilder actually uses.
        // Setting MinRequestBodyDataRate = null disables the worker Kestrel's
        // slow-upload rate monitor (default 240 B/s, 5s grace).
        var host = new HostBuilder()
            .ConfigureFunctionsWebApplication()
            .ConfigureWebHost(webBuilder =>
            {
                webBuilder.ConfigureKestrel(options =>
                {
                    options.Limits.MinRequestBodyDataRate = null;
                });
            })
            .ConfigureServices(services =>
            {
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