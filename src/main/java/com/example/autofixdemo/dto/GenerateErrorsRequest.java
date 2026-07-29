package com.example.autofixdemo.dto;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;

public record GenerateErrorsRequest(
        @NotBlank
        String customerId,

        @Min(1)
        @Max(20)
        int count
) {
}
