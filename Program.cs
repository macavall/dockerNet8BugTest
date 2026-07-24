using Azure.Monitor.OpenTelemetry.Exporter;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Azure.Functions.Worker.OpenTelemetry;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using OpenTelemetry;

internal class Program
{
    private static void Main(string[] args)
    {
        var builder = FunctionsApplication.CreateBuilder(args);

        builder.ConfigureFunctionsWebApplication();

        var openTelemetry = builder.Services.AddOpenTelemetry()
            .UseFunctionsWorkerDefaults();

        // Only wire up the Azure Monitor exporter when a connection string is provided.
        // This lets the app run locally (e.g. in a Docker container) without one.
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("APPLICATIONINSIGHTS_CONNECTION_STRING")))
        {
            openTelemetry.UseAzureMonitorExporter();
        }

        builder.Build().Run();
    }
}