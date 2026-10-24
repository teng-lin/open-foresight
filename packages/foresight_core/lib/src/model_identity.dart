/// Authenticated public production asset already supported by this distribution.
int referenceGenerationModelType(String digest) =>
    digest == '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c'
    ? 14
    : 0;

const referenceManagedModelTypes = {1, 2, 3, 4, 14, 15, 16, 17};
const referenceInferenceModelOrder = [16, 15, 14, 12, 8, 9];
