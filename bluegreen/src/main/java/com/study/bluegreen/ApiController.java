package com.study.bluegreen;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
class ApiController {

    @GetMapping("/")
    public String home() {
        return "Hello from " + System.getenv("APP_ENV") + " environment!";
    }

    @GetMapping("/health")
    public String health() {
        return "OK - " + System.getenv("APP_ENV");
    }

    @GetMapping("/version")
    public String version() {
        return "Version: " + System.getenv("BUILD_NUMBER") + " - Env: " + System.getenv("APP_ENV");
    }
}
