package com.example.autofixdemo.controller;

import com.example.autofixdemo.dto.GenerateErrorsRequest;
import com.example.autofixdemo.dto.GenerateErrorsResponse;
import com.example.autofixdemo.service.CustomerService;
import jakarta.validation.Valid;
import net.logstash.logback.argument.StructuredArguments;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Technical endpoint used to repeatedly trigger the demo error scenario,
 * generating one ERROR log event per iteration.
 */
@RestController
@RequestMapping("/api/demo")
public class DemoController {

    private static final Logger log = LoggerFactory.getLogger(DemoController.class);

    private final CustomerService customerService;

    public DemoController(CustomerService customerService) {
        this.customerService = customerService;
    }

    @PostMapping("/generate-errors")
    public GenerateErrorsResponse generateErrors(@Valid @RequestBody GenerateErrorsRequest request) {
        int generated = 0;

        for (int i = 0; i < request.count(); i++) {
            try {
                customerService.getDisplayName(request.customerId());
            } catch (Exception exception) {
                log.error(
                        "Generated demo error for customerId={} iteration={}",
                        request.customerId(),
                        i + 1,
                        StructuredArguments.kv("customerId", request.customerId()),
                        StructuredArguments.kv("exceptionType", exception.getClass().getName()),
                        StructuredArguments.kv("exceptionMessage", exception.getMessage()),
                        exception
                );
            } finally {
                generated++;
            }
        }

        return new GenerateErrorsResponse(request.count(), generated, request.customerId());
    }
}
