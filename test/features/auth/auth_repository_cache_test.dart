import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/auth/data/auth_repository.dart';
import 'package:vaultsync_client/core/services/api_client.dart';

class MockApiClient extends Mock implements ApiClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AuthRepository authRepository;
  late MockApiClient mockApiClient;
  
  setUp(() {
    mockApiClient = MockApiClient();
    authRepository = AuthRepository(mockApiClient);
  });

  test('checkAuth should return cached user if available', () async {
    final cachedMetadata = {'id': 1, 'email': 'test@example.com'};
    
    when(() => mockApiClient.getToken()).thenAnswer((_) async => 'valid_token');
    when(() => mockApiClient.getUserMetadata()).thenAnswer((_) async => cachedMetadata);
    when(() => mockApiClient.get('/auth/me')).thenAnswer((_) async => cachedMetadata);
    when(() => mockApiClient.setUserMetadata(any())).thenAnswer((_) async {});

    final user = await authRepository.checkAuth();
    
    expect(user, isNotNull);
    expect(user!.email, 'test@example.com');
    expect(user.id, '1');
    
    verify(() => mockApiClient.getUserMetadata()).called(1);
  });
}
