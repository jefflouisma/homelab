# MidPoint FreeIPA Resource Manual Setup

## Issue
MidPoint 4.9 REST API has strict schema validation that prevents creating complex LDAP resources via API. The FreeIPA LDAP resource must be configured manually in the UI.

## Steps to Configure FreeIPA Resource

1. **Access MidPoint UI**
   ```
   http://10.10.10.210:8080/midpoint
   Username: administrator
   Password: 2MEcz|Ra
   ```

2. **Create New Resource**
   - Navigate to **Resources** (left menu)
   - Click **New Resource** (top right)
   - Select **LDAP Connector** (com.evolveum.polygon.connector.ldap.LdapConnector)
   - Click **Next**

3. **Basic Configuration**
   ```
   Name: FreeIPA LDAP
   Description: FreeIPA Identity Server
   ```

4. **Connector Configuration**
   ```
   Host: 10.10.10.212
   Port: 389
   Connection Security: none
   Base DN: dc=practice,dc=local
   Bind DN: uid=midpoint-service,cn=sysaccounts,cn=etc,dc=practice,dc=local
   Password: MidPointLDAP2024!
   Paging Strategy: auto
   ```

5. **Resource Schema**
   - Click **Test Connection** - should succeed
   - Click **Discover Schema** - let it complete
   - Save the resource

6. **Verify Resource**
   - You should see "FreeIPA LDAP" in the Resources list
   - The provisioning job will now work correctly

## After Manual Setup

Once the resource is created:
1. The `user-jeff-provision-updated` job will create users with the FreeIPA role assignment
2. Users will be provisioned from MidPoint → FreeIPA → Keycloak
3. Full IGA flow will be functional

## Why This Approach

- MidPoint 4.9 has complex XML schema requirements for LDAP resources
- The REST API requires all schema elements to be present
- Manual UI configuration is more reliable for complex connectors
- This is a one-time setup step per environment
