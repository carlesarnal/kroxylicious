/*
 * Copyright Kroxylicious Authors.
 *
 * Licensed under the Apache Software License version 2.0, available at http://www.apache.org/licenses/LICENSE-2.0
 */
package io.kroxylicious.proxy.model;

import java.io.FileInputStream;
import java.io.IOException;
import java.security.KeyStore;
import java.security.KeyStoreException;
import java.security.NoSuchAlgorithmException;
import java.security.UnrecoverableKeyException;
import java.security.cert.CertificateException;
import java.util.Optional;
import java.util.Set;
import java.util.stream.Collectors;

import javax.net.ssl.KeyManagerFactory;

import io.netty.handler.ssl.SslContext;
import io.netty.handler.ssl.SslContextBuilder;

import io.kroxylicious.proxy.config.TargetCluster;
import io.kroxylicious.proxy.service.ClusterNetworkAddressConfigProvider;
import io.kroxylicious.proxy.service.HostPort;

public class VirtualCluster implements ClusterNetworkAddressConfigProvider {

    private final TargetCluster targetCluster;

    private final Optional<String> keyStoreFile;
    private final Optional<String> keyPassword;

    private final boolean logNetwork;

    private final boolean logFrames;

    private final ClusterNetworkAddressConfigProvider clusterNetworkAddressConfigProvider;

    public VirtualCluster(TargetCluster targetCluster,
                          ClusterNetworkAddressConfigProvider clusterNetworkAddressConfigProvider,
                          Optional<String> keyStoreFile,
                          Optional<String> keyPassword,
                          boolean logNetwork, boolean logFrames) {
        if (clusterNetworkAddressConfigProvider.requiresTls() && keyStoreFile.isEmpty()) {
            throw new IllegalStateException("Cluster endpoint provider requires tls, but this virtual cluster does not define it");
        }
        var conflicts = clusterNetworkAddressConfigProvider.getExclusivePorts().stream().filter(p -> clusterNetworkAddressConfigProvider.getSharedPorts().contains(p))
                .collect(Collectors.toSet());
        if (!conflicts.isEmpty()) {
            throw new IllegalStateException(
                    "The set of exclusive ports described by the cluster endpoint provider must be distinct from those described as shared. Intersection: " + conflicts);
        }
        this.targetCluster = targetCluster;
        this.logNetwork = logNetwork;
        this.logFrames = logFrames;
        this.keyStoreFile = keyStoreFile;
        this.keyPassword = keyPassword;
        this.clusterNetworkAddressConfigProvider = clusterNetworkAddressConfigProvider;
    }

    public TargetCluster targetCluster() {
        return targetCluster;
    }

    public ClusterNetworkAddressConfigProvider getClusterNetworkAddressConfigProvider() {
        return clusterNetworkAddressConfigProvider;
    }

    public Optional<String> keyStoreFile() {
        return keyStoreFile;
    }

    public Optional<String> keyPassword() {
        return keyPassword;
    }

    public boolean isLogNetwork() {
        return logNetwork;
    }

    public boolean isLogFrames() {
        return logFrames;
    }

    public boolean isUseTls() {
        return keyStoreFile.isPresent();
    }

    public Optional<SslContext> buildSslContext() {

        return keyStoreFile.map(ksf -> {
            try (var is = new FileInputStream(ksf)) {
                var password = keyPassword.map(String::toCharArray).orElse(null);
                var keyStore = KeyStore.getInstance(KeyStore.getDefaultType());
                keyStore.load(is, password);
                var keyManagerFactory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
                keyManagerFactory.init(keyStore, password);
                return SslContextBuilder.forServer(keyManagerFactory).build();
            }
            catch (KeyStoreException | IOException | NoSuchAlgorithmException | CertificateException | UnrecoverableKeyException e) {
                throw new RuntimeException(e);
            }
        });
    }

    @Override
    public String toString() {
        final StringBuilder sb = new StringBuilder("VirtualCluster [");
        sb.append("targetCluster=").append(targetCluster);
        sb.append(", clusterNetworkAddressConfigProvider=").append(clusterNetworkAddressConfigProvider);
        sb.append(", keyStoreFile=").append(keyStoreFile);
        sb.append(", keyPassword=").append(keyPassword);
        sb.append(", logNetwork=").append(logNetwork);
        sb.append(", logFrames=").append(logFrames);
        sb.append(']');
        return sb.toString();
    }

    @Override
    public HostPort getClusterBootstrapAddress() {
        return clusterNetworkAddressConfigProvider.getClusterBootstrapAddress();
    }

    @Override
    public HostPort getBrokerAddress(int nodeId) throws IllegalArgumentException {
        return clusterNetworkAddressConfigProvider.getBrokerAddress(nodeId);
    }

    @Override
    public Optional<String> getBindAddress() {
        return clusterNetworkAddressConfigProvider.getBindAddress();
    }

    @Override
    public boolean requiresTls() {
        return clusterNetworkAddressConfigProvider.requiresTls();
    }

    @Override
    public Set<Integer> getExclusivePorts() {
        return clusterNetworkAddressConfigProvider.getExclusivePorts();
    }

    @Override
    public Set<Integer> getSharedPorts() {
        return clusterNetworkAddressConfigProvider.getSharedPorts();
    }
}
