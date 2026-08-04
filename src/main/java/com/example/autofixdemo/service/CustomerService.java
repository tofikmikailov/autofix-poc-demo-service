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

        // firstName/lastName may be null for some records (e.g. customer "200"
        // by design); treat a null name part as empty rather than throwing NPE.
        return safeTrim(customer.firstName())
                + " "
                + safeTrim(customer.lastName());
    }

    private static String safeTrim(String value) {
        return value == null ? "" : value.trim();
    }
}
