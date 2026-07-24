using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace proj1;

public class http1
{
    private readonly ILogger<http1> _logger;

    public http1(ILogger<http1> logger)
    {
        _logger = logger;
    }

    [Function("http1")]
    public IActionResult Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", "post")] HttpRequest req)
    {
        _logger.LogInformation("C# HTTP trigger function 'http1' processed a request.");
        return new OkObjectResult("Welcome to Azure Functions!");
    }
}
