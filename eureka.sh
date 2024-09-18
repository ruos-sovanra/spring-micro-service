#!/bin/bash

set -euo pipefail

# Variables
project_name=$1
group=$2
JENKINS_URL="http://146.190.89.57:50001"
USER="asura"
API_TOKEN="11d2140b6459df5d77a22d76204adbd795"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Error message for missing dependency
error_exit() {
    echo "$1" 1>&2
    exit 1
}

# Check if required tools are installed
for cmd in gradle git gh curl; do
    command_exists "$cmd" || error_exit "$cmd is not installed. Please install it."
done

# Convert hyphenated string to CamelCase
to_camel_case() {
    echo "$1" | sed -r 's/(^|-)([a-z])/\U\2/g'
}

# Convert project name to lowercase with hyphens
project_name_lower=$(echo "$project_name" | sed 's/\([a-z0-9]\)\([A-Z]\)/\1-\2/g' | tr '[:upper:]' '[:lower:]')
# Convert to CamelCase for the main class
project_name_camel=$(to_camel_case "$project_name")
main_class="${project_name_camel}Application"

# Convert group to package path (dot notation -> slashes)
package_path=$(echo "$group" | tr '.' '/')

# Create project structure
create_project() {
    local project_name_lower=$1
    local main_class=$2
    local dependencies=$3

    project_dir="spring-micro-service/${project_name_lower}"
    src_dir="${project_dir}/src/main/java/${package_path}/${project_name_lower//-/}"

    mkdir -p "$src_dir"

    # Create build.gradle
    cat << EOF > "${project_dir}/build.gradle"
plugins {
    id 'org.springframework.boot' version '3.1.3'
    id 'io.spring.dependency-management' version '1.1.3'
    id 'java'
}

group = '${group}'
version = '0.0.1-SNAPSHOT'
sourceCompatibility = '17'

repositories {
    mavenCentral()
}

ext {
    set('springCloudVersion', "2022.0.4")
}

dependencies {
    ${dependencies}
    testImplementation 'org.springframework.boot:spring-boot-starter-test'
}

dependencyManagement {
    imports {
        mavenBom "org.springframework.cloud:spring-cloud-dependencies:\${springCloudVersion}"
    }
}

tasks.named('test') {
    useJUnitPlatform()
}
EOF

    # Create main application class
    cat << EOF > "${src_dir}/${main_class}.java"
package ${group}.${project_name_lower//-/};

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.netflix.eureka.server.EnableEurekaServer;

@SpringBootApplication
@EnableEurekaServer
public class ${main_class} {
    public static void main(String[] args) {
        SpringApplication.run(${main_class}.class, args);
    }
}
EOF

    # Create application.yml configuration
    mkdir -p "${project_dir}/src/main/resources"
    cat << EOF > "${project_dir}/src/main/resources/application.yml"
spring:
  application:
    name: ${project_name_lower}
  profiles:
    active: dev
server:
  port: 8761

eureka:
  instance:
    hostname: localhost
  client:
    registerWithEureka: false
    fetchRegistry: false
    serviceUrl:
      defaultZone: http://\${eureka.instance.hostname}:\${server.port}/eureka/
  server:
    waitTimeInMsWhenSyncEmpty: 0
    response-cache-update-interval-ms: 5000

management:
  endpoints:
    web:
      exposure:
        include: '*'
EOF

    # Create Dockerfile
    cat << EOF > "${project_dir}/Dockerfile"
# Use official OpenJDK image as the base image
FROM openjdk:17-jdk-alpine

# Set the working directory in the container
WORKDIR /app

# Copy project files
COPY . .

# Download dependencies and build the project
RUN ./gradlew build --no-daemon

# Copy the JAR file into the container
COPY build/libs/*.jar app.jar

# Expose the Eureka port
EXPOSE 8761

# Run the application
ENTRYPOINT ["java", "-jar", "app.jar"]
EOF
}

# Main script execution
create_project "${project_name_lower}" "${main_class}" "implementation 'org.springframework.cloud:spring-cloud-starter-netflix-eureka-server'"

# Initialize Git and push to GitHub
cd "spring-micro-service/${project_name_lower}"
git init
gh repo create ${project_name_lower} --public

git remote add origin https://github.com/ruos-sovanra/${project_name_lower}.git

git branch -M main
git add .
git commit -m "Initial commit"
git push -u origin main

create_jenkins_job() {
    local job_name=$1
    local project_name_lower=$2

    # Jenkins pipeline script with actual variable substitution
    local pipeline_script=$(cat <<EOF
pipeline {
    agent any

    environment {
        GIT_URL = 'https://github.com/ruos-sovanra/${project_name_lower}.git'
        IMAGE_NAME = 'admin.psa-khmer.world/${project_name_lower}'
        BUILD_TAG = "build-\${BUILD_NUMBER}"
        PORT = 8761
        CONTAINER_NAME = sh(script: "echo ${project_name_lower} | sed 's/[^a-zA-Z0-9_.-]//g'", returnStdout: true).trim()
    }

    stages {
        stage('Clone Repository') {
            steps {
                git branch: 'main', url: "\${GIT_URL}"
            }
        }

        stage('Build Docker Image') {
            steps {
                sh "docker build -t \${IMAGE_NAME}:\${BUILD_TAG} ."
            }
        }

        stage('Push Docker Image') {
            steps {
                sh """
                docker login -u admin -p Qwerty@2024 admin.psa-khmer.world
                docker push \${IMAGE_NAME}:\${BUILD_TAG}
                """
            }
        }

        stage('Deploy Application') {
            steps {
                sh """
                docker stop \${CONTAINER_NAME} || true
                docker rm \${CONTAINER_NAME} || true
                docker run -d -p \${PORT}:8761 --name \${CONTAINER_NAME} \${IMAGE_NAME}:\${BUILD_TAG}
                """
            }
        }
    }

    post {
        always {
            echo "Build completed. Eureka Server running on port \${PORT}"
        }
    }
}
EOF
)

    # Job config XML
    local job_config_xml=$(cat <<EOF
<?xml version='1.1' encoding='UTF-8'?>
<flow-definition plugin="workflow-job">
  <actions/>
  <description>Spring Eureka Server Pipeline</description>
  <keepDependencies>false</keepDependencies>
  <properties/>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script><![CDATA[${pipeline_script}]]></script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
EOF
)

    # Create Jenkins job via API
    curl -X POST "${JENKINS_URL}/createItem?name=${job_name}" \
        --user "${USER}:${API_TOKEN}" \
        -H "Content-Type: application/xml" \
        --data-raw "${job_config_xml}" || error_exit "Failed to create Jenkins job"
}




# Jenkins job creation and triggering
create_jenkins_job "${project_name_lower}" "${project_name_lower}"

# Trigger Jenkins job
curl -X POST "${JENKINS_URL}/job/${project_name_lower}/build" --user "${USER}:${API_TOKEN}" || error_exit "Failed to trigger Jenkins job"
