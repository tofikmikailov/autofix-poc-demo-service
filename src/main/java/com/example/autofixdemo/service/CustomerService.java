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

        // Customer "200" has a null firstName by design (controlled demo error
        // scenario). Treat null name parts as empty so the display name is
        // still computed without throwing a NullPointerException.
        String firstName = customer.firstName() == null ? "" : customer.firstName().trim();
        String lastName = customer.lastName() == null ? "" : customer.lastName().trim();
        return (firstName + " " + lastName).trim();
    }
}
