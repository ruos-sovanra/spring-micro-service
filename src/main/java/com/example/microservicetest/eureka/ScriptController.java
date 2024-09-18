package com.example.microservicetest.eureka;


import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.io.BufferedReader;
import java.io.InputStreamReader;

@RestController
@RequestMapping("/script")
public class ScriptController {

    @PostMapping("/run-script")
    public String runScript(@RequestBody ScriptRequest request) {
        StringBuilder output = new StringBuilder();
        try {
            ProcessBuilder processBuilder = new ProcessBuilder("./eureka.sh", request.getProjectName(), request.getGroup());
            processBuilder.redirectErrorStream(true);
            Process process = processBuilder.start();

            BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream()));
            String line;
            while ((line = reader.readLine()) != null) {
                output.append(line).append("\n");
            }

            int exitCode = process.waitFor();
            if (exitCode != 0) {
                return "Script execution failed with exit code " + exitCode;
            }
        } catch (Exception e) {
            return "Script execution failed: " + e.getMessage();
        }
        return output.toString();
    }

}
