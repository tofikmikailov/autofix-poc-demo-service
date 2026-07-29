package com.example.autofixdemo.service;

import com.example.autofixdemo.exception.CustomerNotFoundException;
import com.example.autofixdemo.model.Customer;
import com.example.autofixdemo.repository.CustomerRepository;
import org.springframework.stereotype.Service;

@Service
public class CustomerService {

    private final CustomerRepository customerRepository;

    public CustomerService(CustomerRepository customerRepository) {
        this.customerRepository = customerRepository;
    }

    public String getDisplayName(String customerId) {
        Customer customer = customerRepository.findById(customerId)
                .orElseThrow(() -> new CustomerNotFoundException(customerId));

        // firstName/lastName may be null (e.g. customer "200" by design), so
        // guard against NPE by treating a null part as an empty string.
        String firstName = customer.firstName() == null ? "" : customer.firstName().trim();
        String lastName = customer.lastName() == null ? "" : customer.lastName().trim();

        return (firstName + " " + lastName).trim();
    }
}
