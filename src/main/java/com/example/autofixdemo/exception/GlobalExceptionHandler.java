package com.example.autofixdemo.exception;

import com.example.autofixdemo.logging.CorrelationIdFilter;
import jakarta.servlet.http.HttpServletRequest;
import net.logstash.logback.argument.StructuredArguments;
import org.slf4j.MDC;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;

import java.time.Instant;

/**
 * Converts unhandled exceptions into a single, safe HTTP response format.
 * The full stack trace is only ever written to the log, never returned to
 * the client.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final org.slf4j.Logger log = org.slf4j.LoggerFactory.getLogger(GlobalExceptionHandler.class);

    @ExceptionHandler(CustomerNotFoundException.class)
    public ResponseEntity<ApiErrorResponse> handleCustomerNotFound(
            CustomerNotFoundException exception,
            HttpServletRequest request) {

        log.warn(
                "Customer not found path={}",
                request.getRequestURI(),
                StructuredArguments.kv("httpMethod", request.getMethod()),
                StructuredArguments.kv("requestPath", request.getRequestURI()),
                StructuredArguments.kv("exceptionType", exception.getClass().getName()),
                StructuredArguments.kv("exceptionMessage", exception.getMessage()),
                exception
        );

        ApiErrorResponse body = new ApiErrorResponse(
                Instant.now(),
                HttpStatus.NOT_FOUND.value(),
                HttpStatus.NOT_FOUND.getReasonPhrase(),
                "CUSTOMER_NOT_FOUND",
                exception.getMessage(),
                request.getRequestURI(),
                correlationId()
        );

        return ResponseEntity.status(HttpStatus.NOT_FOUND).body(body);
    }

    @ExceptionHandler(Exception.class)
    public ResponseEntity<ApiErrorResponse> handleUnexpectedException(
            Exception exception,
            HttpServletRequest request) {

        log.error(
                "Unexpected error while processing request path={}",
                request.getRequestURI(),
                StructuredArguments.kv("httpMethod", request.getMethod()),
                StructuredArguments.kv("requestPath", request.getRequestURI()),
                StructuredArguments.kv("exceptionType", exception.getClass().getName()),
                StructuredArguments.kv("exceptionMessage", exception.getMessage()),
                exception
        );

        ApiErrorResponse body = new ApiErrorResponse(
                Instant.now(),
                HttpStatus.INTERNAL_SERVER_ERROR.value(),
                HttpStatus.INTERNAL_SERVER_ERROR.getReasonPhrase(),
                "UNEXPECTED_ERROR",
                "Unexpected application error",
                request.getRequestURI(),
                correlationId()
        );

        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(body);
    }

    private String correlationId() {
        return MDC.get(CorrelationIdFilter.MDC_KEY);
    }
}
