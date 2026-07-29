package com.example.autofixdemo.dto;

public record GenerateErrorsResponse(
        int requested,
        int generated,
        String customerId
) {
}
