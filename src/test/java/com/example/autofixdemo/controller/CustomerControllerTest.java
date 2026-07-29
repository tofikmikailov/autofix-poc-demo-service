package com.example.autofixdemo.controller;

import com.example.autofixdemo.logging.CorrelationIdFilter;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.matchesPattern;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
class CustomerControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Test
    void returnsDisplayNameForExistingCustomer() throws Exception {
        mockMvc.perform(get("/api/customers/100/display-name"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.customerId").value("100"))
                .andExpect(jsonPath("$.displayName").value("Tofik Test"));
    }

    @Test
    void returnsNotFoundForUnknownCustomer() throws Exception {
        mockMvc.perform(get("/api/customers/999/display-name"))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.code").value("CUSTOMER_NOT_FOUND"))
                .andExpect(jsonPath("$.message").value("Customer 999 was not found"))
                .andExpect(jsonPath("$.path").value("/api/customers/999/display-name"))
                .andExpect(jsonPath("$.correlationId").exists());
    }

    @Test
    void generatesCorrelationIdWhenHeaderIsAbsent() throws Exception {
        mockMvc.perform(get("/api/customers/100/display-name"))
                .andExpect(status().isOk())
                .andExpect(header().string(
                        CorrelationIdFilter.CORRELATION_ID_HEADER,
                        matchesPattern("^[0-9a-fA-F-]{36}$")
                ));
    }

    @Test
    void echoesProvidedCorrelationIdHeader() throws Exception {
        mockMvc.perform(get("/api/customers/100/display-name")
                        .header(CorrelationIdFilter.CORRELATION_ID_HEADER, "poc-test-001"))
                .andExpect(status().isOk())
                .andExpect(header().string(CorrelationIdFilter.CORRELATION_ID_HEADER, "poc-test-001"));
    }
}
