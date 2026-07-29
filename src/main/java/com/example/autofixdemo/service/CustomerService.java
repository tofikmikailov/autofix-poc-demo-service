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

        // NOTE: firstName is not null-checked here. Customer "200" has a null
        // firstName by design, so this call deterministically throws a
        // NullPointerException. This is the controlled demo error scenario.
        return customer.firstName().trim()
                + " "
                + customer.lastName().trim();
    }
}
