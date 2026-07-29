package com.example.autofixdemo.model;

/**
 * Simple domain model representing a customer.
 * firstName may legitimately be null for some records (used to trigger
 * the controlled demo error scenario).
 */
public record Customer(
        String id,
        String firstName,
        String lastName,
        String email
) {
}
