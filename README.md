# FHEM-Webuntis
Fhem module to get timetable information from webuntis.

## Features

### Retry Logic for Network Resilience
The module now includes robust retry logic to handle transient network errors:

- **Automatic Retry**: Transient errors (timeouts, connection failures, server errors) are automatically retried
- **Exponential Backoff**: Retry delays increase exponentially (30s, 60s, 120s, etc.) to avoid overwhelming servers
- **Configurable**: Maximum retry attempts and initial delay can be customized via attributes
- **Smart Error Detection**: Distinguishes between transient errors (should retry) and permanent errors (immediate failure)

### New Attributes

- `maxRetries` - Maximum number of retry attempts (0-10, default: 3)
- `retryDelay` - Initial retry delay in seconds (5-300, default: 30)

### Example Configuration

```
attr myWebuntis maxRetries 3
attr myWebuntis retryDelay 30
```

### Transient Errors That Will Be Retried

- Connection timeouts
- Network connection failures 
- DNS resolution failures
- HTTP 502/503/504 server errors
- Malformed/incomplete JSON responses
- Socket errors

### Permanent Errors (No Retry)

- Authentication failures (401, 403)
- Invalid requests (400, 404)
- Configuration errors
- Invalid credentials
