using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace proj1;

public class UploadContent
{
    private readonly ILogger<UploadContent> _logger;

    public UploadContent(ILogger<UploadContent> logger)
    {
        _logger = logger;
    }

    // Reproduces BadHttpRequestException: MinRequestBodyDataRate.
    // Unlike http1, this endpoint fully reads the request body, which is what
    // activates Kestrel's request-body rate monitor (default 240 B/s, 5s grace).
    // A client that trickles bytes below that rate for >5s triggers the timeout.
    [Function("UploadContent")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post")] HttpRequest req)
    {
        _logger.LogInformation("UploadContent: begin reading request body.");

        using var buffer = new MemoryStream();
        await req.Body.CopyToAsync(buffer);

        _logger.LogInformation("UploadContent: received {ByteCount} bytes.", buffer.Length);
        return new OkObjectResult($"Received {buffer.Length} bytes");
    }
}
