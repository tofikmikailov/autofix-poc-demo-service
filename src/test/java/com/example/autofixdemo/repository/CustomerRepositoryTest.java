package com.example.autofixdemo.repository;

import com.example.autofixdemo.model.Customer;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class CustomerRepositoryTest {

    private final CustomerRepository repository = new CustomerRepository();

    @Test
    void findsSeededCustomerById() {
        var customer = repository.findById("100");

        assertThat(customer).isPresent();
        assertThat(customer.get()).isEqualTo(new Customer("100", "Tofik", "Test", "tofik@example.com"));
    }

    @Test
    void returnsEmptyForUnknownCustomer() {
        assertThat(repository.findById("999")).isEmpty();
    }
}
