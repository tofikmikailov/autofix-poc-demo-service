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

        // firstName/lastName may legitimately be null for some records; treat
        // a null value as an empty string instead of throwing an NPE.
        String firstName = customer.firstName() == null ? "" : customer.firstName().trim();
        String lastName = customer.lastName() == null ? "" : customer.lastName().trim();
        return (firstName + " " + lastName).trim();
    }
}
