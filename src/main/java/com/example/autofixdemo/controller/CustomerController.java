package com.example.autofixdemo.controller;

import com.example.autofixdemo.dto.DisplayNameResponse;
import com.example.autofixdemo.service.CustomerService;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/customers")
public class CustomerController {

    private final CustomerService customerService;

    public CustomerController(CustomerService customerService) {
        this.customerService = customerService;
    }

    @GetMapping("/{customerId}/display-name")
    public DisplayNameResponse getDisplayName(@PathVariable String customerId) {
        String displayName = customerService.getDisplayName(customerId);
        return new DisplayNameResponse(customerId, displayName);
    }
}
