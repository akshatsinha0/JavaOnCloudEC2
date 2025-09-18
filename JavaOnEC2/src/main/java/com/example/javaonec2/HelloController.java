package com.example.javaonec2;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
class HelloController{
    @GetMapping("/")
    String hello(){return "OK";}
    @GetMapping("/health")
    String health(){return "OK";}
    @GetMapping("/version")
    String version(){return System.getenv().getOrDefault("APP_VERSION","v1");}
}
