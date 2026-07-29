package com.example.autofixdemo.exception;

import java.time.Instant;

/**
 * Standard error payload returned to API clients.
 * Never includes a stack trace; the full trace is only written to logs.
 */
public record ApiErrorResponse(
        Instant timestamp,
        int status,
        String error,
        String code,
        String message,
        String path,
        String correlationId
) {
}
