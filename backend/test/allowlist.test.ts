import { describe, expect, it } from 'vitest';
import { allow } from '../src/tmdb/allowlist';

const ok = (path: string, query = '') => {
  const result = allow(path, new URLSearchParams(query));
  expect('reason' in result ? result : 'allowed', `${path}?${query}`).toBe('allowed');
};
const refused = (path: string, query = '') => {
  expect('reason' in allow(path, new URLSearchParams(query)), `${path}?${query}`).toBe(true);
};

describe('TMDB allowlist', () => {
  it('accepts every request shape the app makes', () => {
    ok('/movie/popular', 'page=2');
    ok('/tv/popular');
    ok('/discover/movie',
      'primary_release_date.gte=2026-09-01&primary_release_date.lte=2026-10-30&release_date.gte=2026-09-01' +
      '&release_date.lte=2026-10-30&with_release_type=3|4&region=US&sort_by=popularity.desc&vote_count.gte=5&page=1');
    ok('/discover/movie', 'vote_count.gte=25&vote_average.gte=7.0&sort_by=primary_release_date.desc&page=3');
    ok('/discover/tv', 'with_type=2|4&without_genres=10767|10763|10764|10766&air_date.gte=2026-10-01' +
      '&air_date.lte=2026-10-30&sort_by=popularity.desc&vote_count.gte=5&page=1');
    ok('/discover/tv', 'first_air_date.gte=2026-09-01&first_air_date.lte=2026-10-30&sort_by=first_air_date.desc');
    ok('/trending/all/day', 'page=2');
    ok('/movie/550', 'append_to_response=credits,external_ids');
    ok('/tv/1399', 'append_to_response=credits,external_ids&language=en-US');
    ok('/movie/550/recommendations', 'page=2');
    ok('/tv/1399/images', 'include_image_language=en,null');
    ok('/tv/1399/season/3');
    ok('/search/multi', 'query=the%20bear&page=2');
    ok('/find/tt0944947', 'external_source=imdb_id');
  });

  it('refuses unlisted routes', () => {
    refused('/account');
    refused('/authentication/token/new');
    refused('/movie/550/account_states');
    refused('/person/287');
    refused('/movie/abc');
    refused('/movie/0');
    refused('/list/1');
    refused('/movie/550/rating');
  });

  it('refuses path tricks aimed at other hosts or routes', () => {
    refused('//evil.example/movie/550');
    refused('/movie/550/../../account');
    refused('/movie/550%2F..%2Faccount');
    refused('/movie/550?x=1');
    refused('@evil.example/movie/550');
  });

  it('refuses unknown, repeated or malformed parameters', () => {
    refused('/movie/popular', 'api_key=stolen');
    refused('/movie/popular', 'page=0');
    refused('/movie/popular', 'page=501');
    refused('/movie/popular', 'page=1&page=2');
    refused('/discover/movie', 'sort_by=revenue.desc');
    refused('/discover/movie', 'with_release_type=7');
    refused('/discover/movie', 'region=usa');
    refused('/movie/550', 'append_to_response=videos,images,reviews');
    refused('/search/multi', 'query=');
    refused('/search/multi', 'page=2');
    refused('/search/multi', `query=${'a'.repeat(201)}`);
    refused('/search/multi', 'query=a%0Ab');
    refused('/find/tt0944947', 'external_source=tvdb_id');
    refused('/find/tt0944947');
  });
});
