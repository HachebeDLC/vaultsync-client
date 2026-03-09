import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/auth/data/auth_repository.dart';
import 'package:vaultsync_client/core/services/api_client.dart';

class MockApiClient extends Mock implements ApiClient {}

void main() {
  late AuthRepository repository;
  late MockApiClient mockApiClient;

  setUp(() {
    mockApiClient = MockApiClient();
    repository = AuthRepository(mockApiClient);
  });

  test('setupRecovery should normalize answers and call ApiClient', () async {
    final answers = ['Pet ', ' Name', 'City'];
    const salt = 'salt';
    final indices = [0, 1, 2];

    when(() => mockApiClient.setupRecovery(any(), any(), any())).thenAnswer((_) async => Future.value());

    await repository.setupRecovery(answers, salt, indices);

    verify(() => mockApiClient.setupRecovery('pet:name:city', salt, indices)).called(1);
  });

}
