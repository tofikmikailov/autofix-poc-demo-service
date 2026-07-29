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
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Converts unhandled exceptions into a single, safe HTTP response format.
 * The full stack trace is only ever written to the log, never returned to
 * the client.
 */
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final org.slf4j.Logger log = org.slf4j.LoggerFactory.getLogger(GlobalExceptionHandler.class);

    private static final Pattern CUSTOMER_ID_PATTERN = Pattern.compile("^/api/customers/([^/]+)(?:/.*)?$");

    @ExceptionHandler(CustomerNotFoundException.class)
    public ResponseEntity<ApiErrorResponse> handleCustomerNotFound(
            CustomerNotFoundException exception,
            HttpServletRequest request) {

        log.warn(
                "Customer not found path={}",
                logArguments(request, exception).toArray()
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
                logArguments(request, exception).toArray()
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

    /**
     * Builds the structured logging arguments common to every handler, adding
     * a customerId field (extracted from the request path) whenever it is
     * available. The exception must remain the last element so slf4j/logback
     * picks it up as the throwable rather than a format argument.
     */
    private List<Object> logArguments(HttpServletRequest request, Exception exception) {
        List<Object> arguments = new ArrayList<>();
        arguments.add(request.getRequestURI());
        arguments.add(StructuredArguments.kv("httpMethod", request.getMethod()));
        arguments.add(StructuredArguments.kv("requestPath", request.getRequestURI()));
        arguments.add(StructuredArguments.kv("exceptionType", exception.getClass().getName()));
        arguments.add(StructuredArguments.kv("exceptionMessage", exception.getMessage()));

        String customerId = extractCustomerId(request.getRequestURI());
        if (customerId != null) {
            arguments.add(StructuredArguments.kv("customerId", customerId));
        }

        arguments.add(exception);
        return arguments;
    }

    private String extractCustomerId(String requestPath) {
        Matcher matcher = CUSTOMER_ID_PATTERN.matcher(requestPath);
        return matcher.matches() ? matcher.group(1) : null;
    }

    private String correlationId() {
        return MDC.get(CorrelationIdFilter.MDC_KEY);
    }
}

