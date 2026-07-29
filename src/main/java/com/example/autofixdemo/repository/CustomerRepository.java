package com.example.autofixdemo.repository;

import com.example.autofixdemo.model.Customer;
import org.springframework.stereotype.Repository;

import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

/**
 * In-memory repository seeded with fixed demo data.
 * No database is used in this POC stage.
 */
@Repository
public class CustomerRepository {

    private final Map<String, Customer> customers = new ConcurrentHashMap<>();

    public CustomerRepository() {
        customers.put("100", new Customer("100", "Tofik", "Test", "tofik@example.com"));
        // firstName is intentionally null to trigger the controlled demo error scenario.
        customers.put("200", new Customer("200", null, "Broken", "broken@example.com"));
    }

    public Optional<Customer> findById(String id) {
        return Optional.ofNullable(customers.get(id));
    }
}
