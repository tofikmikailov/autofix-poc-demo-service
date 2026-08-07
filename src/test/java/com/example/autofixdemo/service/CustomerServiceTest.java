package com.example.autofixdemo.service;

import com.example.autofixdemo.exception.CustomerNotFoundException;
import com.example.autofixdemo.model.Customer;
import com.example.autofixdemo.repository.CustomerRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;

import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class CustomerServiceTest {

    private CustomerRepository customerRepository;
    private CustomerService customerService;

    @BeforeEach
    void setUp() {
        customerRepository = Mockito.mock(CustomerRepository.class);
        customerService = new CustomerService(customerRepository);
    }

    @Test
    void returnsDisplayNameForExistingCustomer() {
        Mockito.when(customerRepository.findById("100"))
                .thenReturn(Optional.of(new Customer("100", "Tofik", "Test", "tofik@example.com")));

        String displayName = customerService.getDisplayName("100");

        assertThat(displayName).isEqualTo("Tofik Test");
    }

    @Test
    void throwsCustomerNotFoundExceptionForUnknownCustomer() {
        Mockito.when(customerRepository.findById("999")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> customerService.getDisplayName("999"))
                .isInstanceOf(CustomerNotFoundException.class)
                .hasMessageContaining("999");
    }

    @Test
    void returnsLastNameOnlyWhenFirstNameIsNull() {
        Mockito.when(customerRepository.findById("200"))
                .thenReturn(Optional.of(new Customer("200", null, "Smith", "smith@example.com")));

        String displayName = customerService.getDisplayName("200");

        assertThat(displayName).isEqualTo("Smith");
    }

    @Test
    void returnsEmptyStringWhenBothNamesAreNull() {
        Mockito.when(customerRepository.findById("300"))
                .thenReturn(Optional.of(new Customer("300", null, null, "empty@example.com")));

        String displayName = customerService.getDisplayName("300");

        assertThat(displayName).isEqualTo("");
    }
}
