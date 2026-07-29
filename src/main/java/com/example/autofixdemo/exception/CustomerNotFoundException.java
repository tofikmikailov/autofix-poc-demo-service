package com.example.autofixdemo.exception;

/**
 * Thrown when a requested customer does not exist.
 * Handled explicitly to return a controlled 404 response instead of
 * letting the lookup fail with an unchecked exception.
 */
public class CustomerNotFoundException extends RuntimeException {

    public CustomerNotFoundException(String customerId) {
        super("Customer " + customerId + " was not found");
    }
}
